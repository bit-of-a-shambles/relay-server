#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "securerandom"
require "socket"
require "timeout"
require "tmpdir"
require "uri"

ROOT = File.expand_path("..", __dir__)
AGENT_PATH = File.join(ROOT, "scripts", "low_cost_eval_agent.rb")
SMOKE_ROUTING_PATH = File.join(ROOT, "router", "scripts", "smoke-routing.json")

Options = Struct.new(
  :real,
  :tasks,
  :keep,
  :daemon_port,
  :router_port,
  :routing_config,
  :timeout_seconds,
  :learn_routing,
  keyword_init: true
)

class EvalRunner
  TERMINAL_STATUSES = %w[needs_review failed approved rejected].freeze

  def initialize(options)
    @options = options
    @token = "relay-eval-#{SecureRandom.hex(12)}"
    @processes = []
  end

  def run
    if @options.real
      run_real
    else
      run_dry
    end
  ensure
    stop_processes
  end

  private

  def run_dry
    Dir.mktmpdir("relay-low-cost-eval-dry-") do |dir|
      repos = create_fixture_repos(dir, @options.tasks)
      puts JSON.pretty_generate(
        mode: "dry-run",
        tasks: repos.length,
        fixtureRepos: repos.map { |repo| repo[:path] },
        routingConfig: @options.routing_config,
        nextCommand: "OPENROUTER_API_KEY=... scripts/low_cost_eval.rb --real"
      )
    end
  end

  def run_real
    require_openrouter_key_available!

    Dir.mktmpdir("relay-low-cost-eval-") do |dir|
      @tmpdir = dir
      env_paths = prepare_environment(dir)
      create_fixture_repos(File.join(dir, "repos"), @options.tasks)
      build_router!
      start_daemon!(env_paths)
      start_router!(env_paths)
      wait_for_json!("daemon", daemon_url("/healthz"))
      wait_for_json!("router", router_url("/health"))
      repos = register_repos(env_paths[:repos])
      finished = run_tasks(repos)
      outcomes = get_json(daemon_url("/eval/model-outcomes"), auth: true)
      stats = get_json(daemon_url("/stats"), auth: true)

      result = {
        mode: "real",
        learnRouting: @options.learn_routing,
        tasks: finished,
        modelOutcomes: outcomes.fetch("modelOutcomes"),
        stats: stats,
        workdir: @options.keep ? dir : nil,
        routingConfig: env_paths[:routing_config]
      }
      puts JSON.pretty_generate(result.compact)

      if @options.keep
        @tmpdir = nil
      end
    end
  end

  def prepare_environment(dir)
    routing_config = File.join(dir, "routing.json")
    FileUtils.cp(@options.routing_config, routing_config)
    {
      db: File.join(dir, "relay.sqlite3"),
      worktrees: File.join(dir, "worktrees"),
      logs: File.join(dir, "logs"),
      repos: File.join(dir, "repos"),
      routing_config: routing_config,
      call_log: File.join(dir, "llm-calls.jsonl")
    }
  end

  def build_router!
    command = ["npm", "run", "build"]
    stdout, stderr, status = Open3.capture3(*command, chdir: File.join(ROOT, "router"))
    return if status.success?

    warn stdout unless stdout.empty?
    warn stderr unless stderr.empty?
    abort "router build failed"
  end

  def start_daemon!(paths)
    env = {
      "RELAY_SUPERVISE_ROUTER" => "0",
      "RELAY_DAEMON_HOST" => "127.0.0.1",
      "RELAY_DAEMON_PORT" => @options.daemon_port.to_s,
      "RELAY_DAEMON_TOKEN" => @token,
      "RELAY_DB_PATH" => paths[:db],
      "RELAY_WORKTREES_DIR" => paths[:worktrees],
      "RELAY_AGENT_LOG_DIR" => paths[:logs],
      "RELAY_AGENT_COMMAND" => "ruby #{AGENT_PATH}",
      "RELAY_ROUTER_BASE_URL" => router_url("/api")
    }
    env["RELAY_ROUTING_CONFIG"] = paths[:routing_config] if @options.learn_routing
    spawn_process(
      "daemon",
      env,
      ["bundle", "exec", "ruby", "bin/daemon"],
      cwd: File.join(ROOT, "daemon"),
      log_path: File.join(@tmpdir, "daemon.log")
    )
  end

  def start_router!(paths)
    env = {
      "RELAY_ROUTER_HOST" => "127.0.0.1",
      "RELAY_ROUTER_PORT" => @options.router_port.to_s,
      "RELAY_ROUTING_CONFIG" => paths[:routing_config],
      "RELAY_LLM_CALL_LOG" => paths[:call_log],
      "RELAY_LLM_CALL_SINK_URL" => daemon_url("/internal/llm-calls"),
      "RELAY_LLM_CALL_SINK_TOKEN" => @token
    }
    spawn_process(
      "router",
      env,
      ["npm", "run", "start"],
      cwd: File.join(ROOT, "router"),
      log_path: File.join(@tmpdir, "router.log")
    )
  end

  def spawn_process(name, env, argv, cwd:, log_path:)
    log = File.open(log_path, "w")
    pid = Process.spawn(env, *argv, chdir: cwd, out: log, err: [:child, :out])
    @processes << { name: name, pid: pid, log: log, log_path: log_path }
  end

  def stop_processes
    @processes.reverse_each do |process|
      begin
        Process.kill("TERM", process[:pid])
      rescue Errno::ESRCH
        next
      end
    end

    @processes.reverse_each do |process|
      begin
        Timeout.timeout(5) { Process.wait(process[:pid]) }
      rescue Errno::ECHILD, Timeout::Error
        begin
          Process.kill("KILL", process[:pid])
        rescue Errno::ESRCH
          nil
        end
      ensure
        process[:log].close
      end
    end
  end

  def create_fixture_repos(base_dir, count)
    FileUtils.mkdir_p(base_dir)
    count.times.map do |idx|
      path = File.join(base_dir, "eval-#{idx + 1}")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "README.md"), "# Relay eval #{idx + 1}\n")
      run_git!(path, "init", "-b", "main")
      run_git!(path, "config", "user.email", "relay-eval@example.invalid")
      run_git!(path, "config", "user.name", "Relay Eval")
      run_git!(path, "add", ".")
      run_git!(path, "commit", "-m", "initial eval fixture")
      {
        path: path,
        test_command: fixture_test_command
      }
    end
  end

  def register_repos(base_dir)
    Dir.glob(File.join(base_dir, "eval-*")).sort.map do |path|
      post_json(
        daemon_url("/repos"),
        { path: path, testCommand: fixture_test_command },
        auth: true
      )
    end
  end

  def run_tasks(repos)
    repos.map.with_index do |repo, idx|
      task = post_json(
        daemon_url("/tasks"),
        {
          repoId: repo.fetch("id"),
          prompt: "Low-cost eval #{idx + 1}: call the routed model and write its exact reply.",
          qualityDial: 0
        },
        auth: true
      )
      wait_for_task(task)
    end
  end

  def wait_for_task(task)
    deadline = Time.now + @options.timeout_seconds
    loop do
      current = get_json(daemon_url("/tasks/#{task.fetch("id")}"), auth: true)
      return current if TERMINAL_STATUSES.include?(current.fetch("status"))
      abort "timed out waiting for task #{task.fetch("id")}" if Time.now > deadline
      sleep 1
    end
  end

  def fixture_test_command
    "ruby -e 'text=File.read(\"answer.txt\"); abort(\"bad answer\") unless text.include?(\"RELAY_EVAL_OK\")'"
  end

  def wait_for_json!(name, url)
    deadline = Time.now + 30
    loop do
      response = request_json(:get, url, auth: false, allow_failure: true)
      return if response[:code] == 200
      abort "#{name} did not become ready at #{url}" if Time.now > deadline
      sleep 0.5
    end
  end

  def get_json(url, auth:)
    response = request_json(:get, url, auth: auth)
    response.fetch(:body)
  end

  def post_json(url, body, auth:)
    response = request_json(:post, url, body: body, auth: auth)
    response.fetch(:body)
  end

  def request_json(method, url, body: nil, auth:, allow_failure: false)
    uri = URI(url)
    request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    request["authorization"] = "Bearer #{@token}" if auth
    if body
      request["content-type"] = "application/json"
      request.body = JSON.generate(body)
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = 2
      http.read_timeout = 10
      http.request(request)
    end
    parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
    result = { code: response.code.to_i, body: parsed }
    return result if allow_failure || response.is_a?(Net::HTTPSuccess)

    abort "HTTP #{response.code} from #{url}: #{response.body}"
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, JSON::ParserError => e
    return { code: 0, body: nil } if allow_failure

    abort "request failed for #{url}: #{e.message}"
  end

  def run_git!(cwd, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: cwd)
    return if status.success?

    warn stdout unless stdout.empty?
    warn stderr unless stderr.empty?
    abort "git #{args.join(" ")} failed in #{cwd}"
  end

  def daemon_url(path)
    "http://127.0.0.1:#{@options.daemon_port}#{path}"
  end

  def router_url(path)
    "http://127.0.0.1:#{@options.router_port}#{path}"
  end

  def require_openrouter_key_available!
    return if ENV["OPENROUTER_API_KEY"].to_s != ""

    env_path = File.join(ROOT, "router", ".env")
    return if File.file?(env_path) && File.read(env_path).match?(/^OPENROUTER_API_KEY=.+/)

    abort "OPENROUTER_API_KEY is required for --real; set it in the environment or gitignored router/.env"
  end
end

def free_port
  server = TCPServer.new("127.0.0.1", 0)
  server.addr[1]
ensure
  server&.close
end

options = Options.new(
  real: false,
  tasks: 3,
  keep: false,
  daemon_port: free_port,
  router_port: free_port,
  routing_config: SMOKE_ROUTING_PATH,
  timeout_seconds: 120,
  learn_routing: false
)

parser = OptionParser.new do |opts|
  opts.banner = "Usage: scripts/low_cost_eval.rb [--dry-run|--real] [options]"
  opts.on("--dry-run", "Validate fixture generation without network calls or token spend") { options.real = false }
  opts.on("--real", "Run real task-scoped OpenRouter calls through daemon/router") { options.real = true }
  opts.on("--tasks N", Integer, "Number of tiny eval tasks to run (default: 3)") { |value| options.tasks = value }
  opts.on("--keep", "Keep the temporary workdir after a real run") { options.keep = true }
  opts.on("--daemon-port PORT", Integer, "Daemon port (default: random free port)") { |value| options.daemon_port = value }
  opts.on("--router-port PORT", Integer, "Router port (default: random free port)") { |value| options.router_port = value }
  opts.on("--routing-config PATH", String, "Routing config to seed the run (default: router smoke free-model config)") do |value|
    options.routing_config = File.expand_path(value)
  end
  opts.on("--learn-routing", "Allow the daemon to rewrite the temp routing config during the run") { options.learn_routing = true }
  opts.on("--timeout SECONDS", Integer, "Task polling timeout (default: 120)") { |value| options.timeout_seconds = value }
end

parser.parse!

abort "--tasks must be positive" unless options.tasks.positive?
abort "--timeout must be positive" unless options.timeout_seconds.positive?
abort "routing config not found: #{options.routing_config}" unless File.file?(options.routing_config)
abort "agent helper not found: #{AGENT_PATH}" unless File.file?(AGENT_PATH)

EvalRunner.new(options).run
