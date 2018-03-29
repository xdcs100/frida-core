namespace Frida.Agent {
	public void main (string pipe_address, ref Frida.UnloadPolicy unload_policy, Gum.MemoryRange? mapped_range) {
		if (Runner.shared_instance == null)
			Runner.create_and_run (pipe_address, ref unload_policy, mapped_range);
		else
			Runner.resume_after_fork (ref unload_policy);
	}

	private enum StopReason {
		UNLOAD,
		FORK
	}

	private class Runner : Object, AgentSessionProvider, ForkHandler {
		public static Runner shared_instance = null;
		public static Mutex shared_mutex;

		public string pipe_address {
			get;
			construct;
		}

		public StopReason stop_reason {
			default = UNLOAD;
			get;
			set;
		}

		private void * agent_pthread;

		private MainContext main_context;
		private MainLoop main_loop;
		private DBusConnection connection;
		private AgentController controller;
		private bool unloading = false;
		private uint filter_id = 0;
		private uint registration_id = 0;
		private uint pending_calls = 0;
		private Gee.Promise<bool> pending_close;
		private Gee.HashSet<AgentClient> clients = new Gee.HashSet<AgentClient> ();

		private Gum.ScriptBackend script_backend;
		private Gum.Exceptor exceptor;
		private bool jit_enabled = false;
		protected Gum.MemoryRange agent_range;

		private ForkListener fork_listener;
		private ThreadIgnoreScope fork_ignore_scope;
		private uint fork_parent_pid;
		private uint fork_child_pid;
		private HostChildId fork_child_id;
		private uint fork_parent_injectee_id;
		private uint fork_child_injectee_id;
		private Socket fork_child_socket;
		private ForkRecoveryState fork_recovery_state;
		private Mutex fork_mutex;
		private Cond fork_cond;

		private enum ForkRecoveryState {
			RECOVERING,
			RECOVERED
		}

		private enum ForkActor {
			PARENT,
			CHILD
		}

		public static void create_and_run (string pipe_address, ref Frida.UnloadPolicy unload_policy, Gum.MemoryRange? mapped_range) {
			Environment._init ();

			{
				var agent_range = memory_range (mapped_range);
				Gum.Cloak.add_range (agent_range);

				var ignore_scope = new ThreadIgnoreScope ();

				shared_instance = new Runner (pipe_address, agent_range);

				try {
					shared_instance.run ();
				} catch (Error e) {
					printerr ("Unable to start agent: %s\n", e.message);
				}

				if (shared_instance.stop_reason == FORK) {
					unload_policy = DEFERRED;
					return;
				} else {
					release_shared_instance ();
				}

				ignore_scope = null;
			}

			Environment._deinit ();
		}

		public static void resume_after_fork (ref Frida.UnloadPolicy unload_policy) {
			{
				var ignore_scope = new ThreadIgnoreScope ();

				shared_instance.run_after_fork ();

				if (shared_instance.stop_reason == FORK) {
					unload_policy = DEFERRED;
					return;
				} else {
					release_shared_instance ();
				}

				ignore_scope = null;
			}

			Environment._deinit ();
		}

		private static void release_shared_instance () {
			shared_mutex.lock ();
			var instance = shared_instance;
			shared_instance = null;
			shared_mutex.unlock ();

			instance = null;
		}

		private Runner (string pipe_address, Gum.MemoryRange agent_range) {
			Object (pipe_address: pipe_address);

			this.agent_range = agent_range;
		}

		construct {
			agent_pthread = Environment._get_current_pthread ();

			main_context = new MainContext ();
			main_loop = new MainLoop (main_context);

#if !WINDOWS
			var interceptor = Gum.Interceptor.obtain ();
			interceptor.begin_transaction ();
#endif

			exceptor = Gum.Exceptor.obtain ();

#if !WINDOWS
			fork_listener = new ForkListener (this);

			interceptor.attach_listener ((void *) Posix.fork, fork_listener);
			interceptor.replace_function ((void *) Posix.vfork, (void *) Posix.fork);

			interceptor.end_transaction ();
#endif
		}

		~Runner () {
#if !WINDOWS
			var interceptor = Gum.Interceptor.obtain ();
			interceptor.begin_transaction ();

			interceptor.revert_function ((void *) Posix.vfork);
			interceptor.detach_listener (fork_listener);

			exceptor = null;

			interceptor.end_transaction ();
#endif
		}

		private void run () throws Error {
			main_context.push_thread_default ();

			setup_connection_with_pipe_address.begin (pipe_address);

			main_loop.run ();

			main_context.pop_thread_default ();
		}

		private void run_after_fork () {
			fork_mutex.lock ();
			fork_mutex.unlock ();

			stop_reason = UNLOAD;
			agent_pthread = Environment._get_current_pthread ();

			main_context.push_thread_default ();
			main_loop.run ();
			main_context.pop_thread_default ();
		}

#if WINDOWS
		private void prepare_to_fork () {
		}

		private void recover_from_fork_in_parent () {
		}

		private void recover_from_fork_in_child () {
		}
#else
		private void prepare_to_fork () {
			fork_ignore_scope = new ThreadIgnoreScope ();

			schedule_idle (() => {
				do_prepare_to_fork.begin ();
				return false;
			});
			Environment._join_pthread (agent_pthread);

			GumJS.prepare_to_fork ();
			Gum.prepare_to_fork ();
			GIOFork.prepare_to_fork ();
			GLibFork.prepare_to_fork ();
			Gum.Memory.prepare_to_fork ();
		}

		private async void do_prepare_to_fork () {
			stop_reason = FORK;

			try {
				fork_parent_pid = Posix.getpid ();
				fork_child_id = yield controller.prepare_to_fork (fork_parent_pid, out fork_parent_injectee_id, out fork_child_injectee_id, out fork_child_socket);
			} catch (GLib.Error e) {
				assert_not_reached ();
			}

			main_loop.quit ();
		}

		private void recover_from_fork_in_parent () {
			recover_from_fork (ForkActor.PARENT);
		}

		private void recover_from_fork_in_child () {
			recover_from_fork (ForkActor.CHILD);
		}

		private void recover_from_fork (ForkActor actor) {
			if (actor == PARENT) {
				Gum.Memory.recover_from_fork_in_parent ();
				GLibFork.recover_from_fork_in_parent ();
				GIOFork.recover_from_fork_in_parent ();
				Gum.recover_from_fork_in_parent ();
				GumJS.recover_from_fork_in_parent ();
			} else if (actor == CHILD) {
				Gum.Memory.recover_from_fork_in_child ();
				GLibFork.recover_from_fork_in_child ();
				GIOFork.recover_from_fork_in_child ();
				Gum.recover_from_fork_in_child ();
				GumJS.recover_from_fork_in_child ();

				fork_child_pid = Posix.getpid ();

				discard_connection ();
			}

			fork_mutex.lock ();

			fork_recovery_state = RECOVERING;

			schedule_idle (() => {
				recreate_agent_thread.begin (actor);
				return false;
			});

			main_context.push_thread_default ();
			main_loop.run ();
			main_context.pop_thread_default ();

			schedule_idle (() => {
				finish_recovery_from_fork.begin (actor);
				return false;
			});

			while (fork_recovery_state != RECOVERED)
				fork_cond.wait (fork_mutex);

			fork_mutex.unlock ();

			fork_ignore_scope = null;
		}

		private async void recreate_agent_thread (ForkActor actor) {
			uint pid, injectee_id;
			if (actor == PARENT) {
				pid = fork_parent_pid;
				injectee_id = fork_parent_injectee_id;
			} else if (actor == CHILD) {
				yield close_all_clients ();

				var stream = SocketConnection.factory_create_connection (fork_child_socket);
				yield setup_connection_with_stream (stream);

				pid = fork_child_pid;
				injectee_id = fork_child_injectee_id;
			} else {
				assert_not_reached ();
			}

			try {
				yield controller.recreate_agent_thread (pid, injectee_id);
			} catch (GLib.Error e) {
				assert_not_reached ();
			}

			main_loop.quit ();
		}

		private async void finish_recovery_from_fork (ForkActor actor) {
			if (actor == CHILD) {
				var info = HostChildInfo (fork_child_pid, Environment.get_program_name (), fork_parent_pid);
				try {
					yield controller.wait_for_permission_to_resume (fork_child_id, info);
				} catch (GLib.Error e) {
					// The connection will/did get closed and we will unload...
				}
			}

			fork_parent_pid = 0;
			fork_child_pid = 0;
			fork_child_id = HostChildId (0);
			fork_parent_injectee_id = 0;
			fork_child_injectee_id = 0;
			fork_child_socket = null;

			fork_mutex.lock ();
			fork_recovery_state = RECOVERED;
			fork_cond.signal ();
			fork_mutex.unlock ();
		}
#endif

		private async void open (AgentSessionId id) throws Error {
			if (unloading)
				throw new Error.INVALID_OPERATION ("Agent is unloading");

			var client = new AgentClient (this, id);
			clients.add (client);
			client.closed.connect (on_client_closed);

			try {
				AgentSession session = client;
				client.registration_id = connection.register_object (ObjectPath.from_agent_session_id (id), session);
			} catch (IOError io_error) {
				assert_not_reached ();
			}

			opened (id);
		}

		private async void close_all_clients () {
			foreach (var client in clients.to_array ()) {
				try {
					yield client.close ();
				} catch (GLib.Error e) {
					assert_not_reached ();
				}
			}
			assert (clients.is_empty);
		}

		private void on_client_closed (AgentClient client) {
			closed (client.id);

			var id = client.registration_id;
			if (id != 0) {
				connection.unregister_object (id);
				client.registration_id = 0;
			}

			client.closed.disconnect (on_client_closed);
			clients.remove (client);
		}

		private async void unload () throws Error {
			if (unloading)
				throw new Error.INVALID_OPERATION ("Agent is already unloading");
			unloading = true;
			perform_unload.begin ();
		}

		private async void perform_unload () {
			Gee.Promise<bool> operation = null;

			lock (pending_calls) {
				if (pending_calls > 0) {
					pending_close = new Gee.Promise<bool> ();
					operation = pending_close;
				}
			}

			if (operation != null) {
				try {
					yield operation.future.wait_async ();
				} catch (Gee.FutureError e) {
					assert_not_reached ();
				}
			}

			yield close_all_clients ();

			yield teardown_connection ();

			schedule_idle (() => {
				main_loop.quit ();
				return false;
			});
		}

		public ScriptEngine create_script_engine () {
			if (script_backend == null)
				script_backend = Environment._obtain_script_backend (jit_enabled);

			return new ScriptEngine (script_backend, agent_range);
		}

		public void enable_jit () throws Error {
			if (jit_enabled)
				return;

			if (script_backend != null)
				throw new Error.INVALID_OPERATION ("JIT may only be enabled before the first script is created");

			jit_enabled = true;
		}

		public void schedule_idle (owned SourceFunc function) {
			var source = new IdleSource ();
			source.set_callback ((owned) function);
			source.attach (main_context);
		}

		public void schedule_timeout (uint delay, owned SourceFunc function) {
			var source = new TimeoutSource (delay);
			source.set_callback ((owned) function);
			source.attach (main_context);
		}

		private async void setup_connection_with_pipe_address (string pipe_address) {
			IOStream stream;
			try {
				stream = yield Pipe.open (pipe_address).future.wait_async ();
			} catch (Gee.FutureError e) {
				assert_not_reached ();
			}

			yield setup_connection_with_stream (stream);
		}

		private async void setup_connection_with_stream (IOStream stream) {
			try {
				connection = yield new DBusConnection (stream, null, AUTHENTICATION_CLIENT | DELAY_MESSAGE_PROCESSING);
			} catch (GLib.Error connection_error) {
				printerr ("Unable to create connection: %s\n", connection_error.message);
				return;
			}

			connection.on_closed.connect (on_connection_closed);
			filter_id = connection.add_filter (on_connection_message);

			try {
				AgentSessionProvider provider = this;
				registration_id = connection.register_object (ObjectPath.AGENT_SESSION_PROVIDER, provider);

				connection.start_message_processing ();
			} catch (IOError io_error) {
				assert_not_reached ();
			}

			try {
				controller = yield connection.get_proxy (null, ObjectPath.AGENT_CONTROLLER, DBusProxyFlags.NONE, null);
			} catch (GLib.Error e) {
				assert_not_reached ();
			}
		}

		private async void teardown_connection () {
			if (connection == null)
				return;

			connection.on_closed.disconnect (on_connection_closed);

			try {
				yield connection.flush ();
			} catch (GLib.Error e) {
			}

			try {
				yield connection.close ();
			} catch (GLib.Error e) {
			}

			unregister_connection ();

			connection = null;
		}

		private void discard_connection () {
			if (connection == null)
				return;

			connection.on_closed.disconnect (on_connection_closed);

			unregister_connection ();

			connection.dispose ();
			connection = null;
		}

		private void unregister_connection () {
			foreach (var client in clients) {
				connection.unregister_object (client.registration_id);
				client.registration_id = 0;
			}

			controller = null;

			if (registration_id != 0) {
				connection.unregister_object (registration_id);
				registration_id = 0;
			}

			if (filter_id != 0) {
				connection.remove_filter (filter_id);
				filter_id = 0;
			}
		}

		private void on_connection_closed (DBusConnection connection, bool remote_peer_vanished, GLib.Error? error) {
			bool closed_by_us = (!remote_peer_vanished && error == null);
			if (!closed_by_us)
				unload.begin ();

			Gee.Promise<bool> operation = null;
			lock (pending_calls) {
				pending_calls = 0;
				operation = pending_close;
				pending_close = null;
			}
			if (operation != null)
				operation.set_value (true);
		}

		private GLib.DBusMessage on_connection_message (DBusConnection connection, owned DBusMessage message, bool incoming) {
			switch (message.get_message_type ()) {
				case DBusMessageType.METHOD_CALL:
					if (incoming) {
						lock (pending_calls) {
							pending_calls++;
						}
					}
					break;
				case DBusMessageType.METHOD_RETURN:
				case DBusMessageType.ERROR:
					if (!incoming) {
						lock (pending_calls) {
							pending_calls--;
							var operation = pending_close;
							if (pending_calls == 0 && operation != null) {
								pending_close = null;
								schedule_idle (() => {
									operation.set_value (true);
									return false;
								});
							}
						}
					}
					break;
				default:
					break;
			}

			return message;
		}
	}

	private class AgentClient : Object, AgentSession {
		public signal void closed (AgentClient client);

		public weak Runner runner {
			get;
			construct;
		}

		public AgentSessionId id {
			get;
			construct;
		}

		public uint registration_id {
			get;
			set;
		}

		private Gee.Promise<bool> close_request;

		private ScriptEngine script_engine;

		public AgentClient (Runner runner, AgentSessionId id) {
			Object (runner: runner, id: id);
		}

		public async void close () throws Error {
			if (close_request != null) {
				try {
					yield close_request.future.wait_async ();
				} catch (Gee.FutureError e) {
					assert_not_reached ();
				}
				return;
			}
			close_request = new Gee.Promise<bool> ();

			if (script_engine != null) {
				yield script_engine.shutdown ();
				script_engine = null;
			}

			closed (this);

			close_request.set_value (true);
		}

		public async AgentScriptId create_script (string name, string source) throws Error {
			var engine = get_script_engine ();
			var instance = yield engine.create_script ((name != "") ? name : null, source, null);
			return instance.sid;
		}

		public async AgentScriptId create_script_from_bytes (uint8[] bytes) throws Error {
			var engine = get_script_engine ();
			var instance = yield engine.create_script (null, null, new Bytes (bytes));
			return instance.sid;
		}

		public async uint8[] compile_script (string name, string source) throws Error {
			var engine = get_script_engine ();
			var bytes = yield engine.compile_script ((name != "") ? name : null, source);
			return bytes.get_data ();
		}

		public async void destroy_script (AgentScriptId sid) throws Error {
			var engine = get_script_engine ();
			yield engine.destroy_script (sid);
		}

		public async void load_script (AgentScriptId sid) throws Error {
			var engine = get_script_engine ();
			yield engine.load_script (sid);
		}

		public async void post_to_script (AgentScriptId sid, string message, bool has_data, uint8[] data) throws Error {
			get_script_engine ().post_to_script (sid, message, has_data ? new Bytes (data) : null);
		}

		public async void enable_debugger () throws Error {
			get_script_engine ().enable_debugger ();
		}

		public async void disable_debugger () throws Error {
			get_script_engine ().disable_debugger ();
		}

		public async void post_message_to_debugger (string message) throws Error {
			get_script_engine ().post_message_to_debugger (message);
		}

		public async void enable_jit () throws GLib.Error {
			runner.enable_jit ();
		}

		private ScriptEngine get_script_engine () throws Error {
			check_open ();

			if (script_engine == null) {
				script_engine = runner.create_script_engine ();
				script_engine.message_from_script.connect ((script_id, message, data) => {
					var has_data = data != null;
					var data_param = has_data ? data.get_data () : new uint8[0];
					this.message_from_script (script_id, message, has_data, data_param);
				});
				script_engine.message_from_debugger.connect ((message) => this.message_from_debugger (message));
			}

			return script_engine;
		}

		private void check_open () throws Error {
			if (close_request != null)
				throw new Error.INVALID_OPERATION ("Session is closing");
		}
	}

	private Gum.MemoryRange memory_range (Gum.MemoryRange? mapped_range) {
		Gum.MemoryRange? result = mapped_range;

		if (result == null) {
			Gum.Process.enumerate_modules ((details) => {
				if (details.name.index_of ("frida-agent") != -1) {
					result = details.range;
					return false;
				}
				return true;
			});
			assert (result != null);
		}

		return result;
	}

	private class ThreadIgnoreScope {
		private Gum.Interceptor interceptor;

		private Gum.ThreadId thread_id;

		private uint num_ranges;
		private Gum.MemoryRange ranges[2];

		public ThreadIgnoreScope () {
			interceptor = Gum.Interceptor.obtain ();
			interceptor.ignore_current_thread ();

			thread_id = Gum.Process.get_current_thread_id ();
			Gum.Cloak.add_thread (thread_id);

			num_ranges = Gum.Thread.try_get_ranges (ranges);
			for (var i = 0; i != num_ranges; i++)
				Gum.Cloak.add_range (ranges[i]);
		}

		~ThreadIgnoreScope () {
			for (var i = 0; i != num_ranges; i++)
				Gum.Cloak.remove_range (ranges[i]);

			Gum.Cloak.remove_thread (thread_id);

			interceptor.unignore_current_thread ();
		}
	}

	private class ForkListener : Object, Gum.InvocationListener {
		public unowned ForkHandler handler {
			get;
			construct;
		}

		public ForkListener (ForkHandler handler) {
			Object (handler: handler);
		}

		public void on_enter (Gum.InvocationContext context) {
			handler.prepare_to_fork ();
		}

		public void on_leave (Gum.InvocationContext context) {
			int result = (int) context.get_return_value ();
			if (result != 0)
				handler.recover_from_fork_in_parent ();
			else
				handler.recover_from_fork_in_child ();
		}
	}

	public interface ForkHandler : Object {
		public abstract void prepare_to_fork ();
		public abstract void recover_from_fork_in_parent ();
		public abstract void recover_from_fork_in_child ();
	}

	namespace Environment {
		public extern void _init ();
		public extern void _deinit ();

		public extern unowned Gum.ScriptBackend _obtain_script_backend (bool jit_enabled);

		public string get_program_name () {
			var name = _try_get_program_name ();
			if (name != null)
				return name;

			Gum.Process.enumerate_modules ((details) => {
				name = details.name;
				return false;
			});
			assert (name != null);

			return name;
		}

		public extern string? _try_get_program_name ();
		public extern void * _get_current_pthread ();
		public extern void _join_pthread (void * thread);
	}

	private Mutex gc_mutex;
	private uint gc_generation = 0;
	private bool gc_scheduled = false;

	public void _on_pending_garbage (void * data) {
		gc_mutex.lock ();
		gc_generation++;
		bool already_scheduled = gc_scheduled;
		gc_scheduled = true;
		gc_mutex.unlock ();

		if (already_scheduled)
			return;

		Runner.shared_mutex.lock ();
		var runner = Runner.shared_instance;
		Runner.shared_mutex.unlock ();

		if (runner == null)
			return;

		runner.schedule_timeout (50, () => {
			gc_mutex.lock ();
			uint generation = gc_generation;
			gc_mutex.unlock ();

			bool collected_everything = garbage_collect ();

			gc_mutex.lock ();
			bool same_generation = generation == gc_generation;
			bool repeat = !collected_everything || !same_generation;
			if (!repeat)
				gc_scheduled = false;
			gc_mutex.unlock ();

			return repeat;
		});
	}

	[CCode (cname = "g_thread_garbage_collect")]
	private extern bool garbage_collect ();

	[CCode (cheader_filename = "glib.h", lower_case_cprefix = "glib_")]
	namespace GLibFork {
		public extern void prepare_to_fork ();
		public extern void recover_from_fork_in_parent ();
		public extern void recover_from_fork_in_child ();
	}

	[CCode (cheader_filename = "gio/gio.h", lower_case_cprefix = "gio_")]
	namespace GIOFork {
		public extern void prepare_to_fork ();
		public extern void recover_from_fork_in_parent ();
		public extern void recover_from_fork_in_child ();
	}
}
