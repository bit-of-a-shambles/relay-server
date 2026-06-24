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
  :max_tokens,
  keyword_init: true
)

Fixture = Struct.new(
  :id,
  :category,
  :prompt,
  :files,
  :editable_files,
  :test_command,
  keyword_init: true
)

FIXTURES = [
  Fixture.new(
    id: "bug-final-price",
    category: "bug fix",
    prompt: "Fix final_price_cents so it returns the customer final price after the percent discount.",
    editable_files: ["discount.rb"],
    test_command: "ruby test_discount.rb",
    files: {
      "discount.rb" => <<~RUBY,
        def final_price_cents(price_cents, percent_off)
          price_cents * percent_off / 100
        end
      RUBY
      "test_discount.rb" => <<~RUBY
        require_relative "./discount"

        def assert_equal(expected, actual)
          raise "expected \#{expected.inspect}, got \#{actual.inspect}" unless expected == actual
        end

        assert_equal 750, final_price_cents(1000, 25)
        assert_equal 1000, final_price_cents(1000, 0)
        assert_equal 0, final_price_cents(1000, 100)
      RUBY
    }
  ),
  Fixture.new(
    id: "behavior-greeting",
    category: "unit test/task behavior change",
    prompt: "Change greeting_for so it trims names, uses guest for nil or blank names, and adds an exclamation mark.",
    editable_files: ["greeting.rb"],
    test_command: "ruby test_greeting.rb",
    files: {
      "greeting.rb" => <<~RUBY,
        def greeting_for(name)
          "Hello, \#{name}"
        end
      RUBY
      "test_greeting.rb" => <<~RUBY
        require_relative "./greeting"

        def assert_equal(expected, actual)
          raise "expected \#{expected.inspect}, got \#{actual.inspect}" unless expected == actual
        end

        assert_equal "Hello, Ada!", greeting_for(" Ada ")
        assert_equal "Hello, guest!", greeting_for("   ")
        assert_equal "Hello, guest!", greeting_for(nil)
      RUBY
    }
  ),
  Fixture.new(
    id: "refactor-score-summary",
    category: "refactor-with-tests",
    prompt: "Extract normalize_scores(scores), have both public methods use it, discard nils, round numeric scores, and count passing scores at 70 or above.",
    editable_files: ["scores.rb"],
    test_command: "ruby test_scores.rb",
    files: {
      "scores.rb" => <<~RUBY,
        def passing_scores(scores)
          scores.select { |score| score >= 60 }.map { |score| score.round }
        end

        def score_summary(scores)
          passed = scores.select { |score| score >= 60 }.map { |score| score.round }
          "\#{passed.length}/\#{scores.length} passing: \#{passed.join(",")}"
        end
      RUBY
      "test_scores.rb" => <<~RUBY
        require_relative "./scores"

        def assert_equal(expected, actual)
          raise "expected \#{expected.inspect}, got \#{actual.inspect}" unless expected == actual
        end

        scores = [69.6, nil, 88.2, 40.1]
        assert_equal [70, 88, 40], normalize_scores(scores)
        assert_equal [70, 88], passing_scores(scores)
        assert_equal "2/4 passing: 70,88", score_summary(scores)
      RUBY
    }
  ),
  Fixture.new(
    id: "parser-settings",
    category: "parsing/string edge case",
    prompt: "Make parse_settings accept comma or semicolon separators, strip whitespace, split on only the first colon, ignore empty pairs, and return an empty hash for nil or blank input.",
    editable_files: ["settings_parser.rb"],
    test_command: "ruby test_settings_parser.rb",
    files: {
      "settings_parser.rb" => <<~RUBY,
        def parse_settings(input)
          input.split(",").map { |pair| pair.split(":") }.to_h
        end
      RUBY
      "test_settings_parser.rb" => <<~RUBY
        require_relative "./settings_parser"

        def assert_equal(expected, actual)
          raise "expected \#{expected.inspect}, got \#{actual.inspect}" unless expected == actual
        end

        assert_equal(
          { "mode" => "fast", "path" => "a:b", "retry" => "3" },
          parse_settings(" mode : fast ; path: a:b, retry : 3 ,, ")
        )
        assert_equal({}, parse_settings(nil))
        assert_equal({}, parse_settings(" ; , "))
      RUBY
    }
  ),
  Fixture.new(
    id: "cli-status-output",
    category: "CLI/output behavior",
    prompt: "Update relay_status.rb so NAME is required. Default output is 'Relay ready for NAME'. With --json NAME, output compact JSON with name and status. Missing name exits nonzero and prints usage to stderr.",
    editable_files: ["relay_status.rb"],
    test_command: "ruby test_relay_status.rb",
    files: {
      "relay_status.rb" => <<~RUBY,
        name = ARGV[0] || "Relay"
        puts "relay \#{name}"
      RUBY
      "test_relay_status.rb" => <<~RUBY
        require "json"
        require "open3"
        require "rbconfig"

        def run_cli(*args)
          Open3.capture3(RbConfig.ruby, "relay_status.rb", *args)
        end

        out, err, status = run_cli("Ada")
        raise "expected success" unless status.success?
        raise "bad stdout: \#{out.inspect}" unless out == "Relay ready for Ada\\n"
        raise "bad stderr: \#{err.inspect}" unless err == ""

        out, err, status = run_cli("--json", "Ada")
        raise "expected success" unless status.success?
        raise "bad json" unless JSON.parse(out) == { "name" => "Ada", "status" => "ready" }
        raise "bad stderr: \#{err.inspect}" unless err == ""

        out, err, status = run_cli
        raise "expected failure" if status.success?
        raise "expected usage" unless err.include?("usage: relay_status [--json] NAME")
        raise "expected empty stdout" unless out == ""
      RUBY
    }
  )
].freeze

class EvalRunner
  TERMINAL_STATUSES = %w[needs_review failed approved rejected].freeze

  def initialize(options)
    @options = options
    @fixtures = FIXTURES.first(options.tasks)
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
    Dir.mktmpdir("relay-coding-eval-dry-") do |dir|
      repos = create_fixture_repos(File.join(dir, "repos"))
      checks = repos.map do |repo|
        status = run_shell(repo[:fixture].test_command, cwd: repo[:path])
        {
          fixture: repo[:fixture].id,
          category: repo[:fixture].category,
          path: repo[:path],
          initialTestsPassed: status.success?
        }
      end

      if checks.any? { |check| check[:initialTestsPassed] }
        abort "dry-run expected every fixture to fail before model edits"
      end

      puts JSON.pretty_generate(
        mode: "dry-run",
        fixtures: checks,
        routingConfig: @options.routing_config,
        maxTokens: @options.max_tokens,
        nextCommand: "OPENROUTER_API_KEY=... scripts/low_cost_eval.rb --real"
      )
    end
  end

  def run_real
    require_openrouter_key_available!

    Dir.mktmpdir("relay-coding-eval-") do |dir|
      @tmpdir = dir
      env_paths = prepare_environment(dir)
      create_fixture_repos(env_paths[:repos])
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
        maxTokens: @options.max_tokens,
        taskResults: summarize_tasks(finished),
        modelOutcomes: outcomes.fetch("modelOutcomes"),
        stats: stats,
        workdir: @options.keep ? dir : nil,
        routingConfig: env_paths[:routing_config]
      }
      puts JSON.pretty_generate(result.compact)

      @tmpdir = nil if @options.keep
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
    stdout, stderr, status = Open3.capture3("npm", "run", "build", chdir: File.join(ROOT, "router"))
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

  def create_fixture_repos(base_dir)
    FileUtils.mkdir_p(base_dir)
    @fixtures.map.with_index do |fixture, idx|
      path = File.join(base_dir, format("%02d-%s", idx + 1, fixture.id))
      FileUtils.mkdir_p(path)
      fixture.files.each do |relative_path, content|
        target = File.join(path, relative_path)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, content)
      end
      write_eval_task(path, fixture)
      run_git!(path, "init", "-b", "main")
      run_git!(path, "config", "user.email", "relay-eval@example.invalid")
      run_git!(path, "config", "user.name", "Relay Eval")
      run_git!(path, "add", ".")
      run_git!(path, "commit", "-m", "initial eval fixture")
      { path: path, fixture: fixture }
    end
  end

  def write_eval_task(path, fixture)
    File.write(
      File.join(path, "eval_task.json"),
      JSON.pretty_generate(
        id: fixture.id,
        category: fixture.category,
        prompt: fixture.prompt,
        editableFiles: fixture.editable_files,
        testCommand: fixture.test_command
      )
    )
  end

  def register_repos(base_dir)
    @fixtures.map.with_index do |fixture, idx|
      path = File.join(base_dir, format("%02d-%s", idx + 1, fixture.id))
      repo = post_json(
        daemon_url("/repos"),
        { path: path, testCommand: fixture.test_command },
        auth: true
      )
      { repo: repo, fixture: fixture }
    end
  end

  def run_tasks(repos)
    repos.map do |repo_spec|
      fixture = repo_spec.fetch(:fixture)
      task = post_json(
        daemon_url("/tasks"),
        {
          repoId: repo_spec.fetch(:repo).fetch("id"),
          prompt: "#{fixture.category}: #{fixture.prompt}",
          qualityDial: 0
        },
        auth: true
      )
      { fixture: fixture, task: wait_for_task(task) }
    end
  end

  def summarize_tasks(finished)
    finished.map do |item|
      task = item.fetch(:task)
      fixture = item.fetch(:fixture)
      {
        fixture: fixture.id,
        category: fixture.category,
        status: task.fetch("status"),
        testsPassed: task["testsPassed"],
        costUsd: task["costUsd"],
        savedUsd: task["savedUsd"]
      }
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

  def run_shell(command, cwd:)
    _stdout, _stderr, status = Open3.capture3("sh", "-c", command, chdir: cwd)
    status
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
  tasks: FIXTURES.length,
  keep: false,
  daemon_port: free_port,
  router_port: free_port,
  routing_config: SMOKE_ROUTING_PATH,
  timeout_seconds: 180,
  learn_routing: false,
  max_tokens: 900
)

parser = OptionParser.new do |opts|
  opts.banner = "Usage: scripts/low_cost_eval.rb [--dry-run|--real] [options]"
  opts.on("--dry-run", "Validate fixture generation without network calls or token spend") { options.real = false }
  opts.on("--real", "Run real task-scoped OpenRouter calls through daemon/router") { options.real = true }
  opts.on("--tasks N", Integer, "Number of fixtures to run from the suite (default: all #{FIXTURES.length})") { |value| options.tasks = value }
  opts.on("--keep", "Keep the temporary workdir after a real run") { options.keep = true }
  opts.on("--daemon-port PORT", Integer, "Daemon port (default: random free port)") { |value| options.daemon_port = value }
  opts.on("--router-port PORT", Integer, "Router port (default: random free port)") { |value| options.router_port = value }
  opts.on("--routing-config PATH", String, "Routing config to seed the run (default: router smoke free-model config)") do |value|
    options.routing_config = File.expand_path(value)
  end
  opts.on("--learn-routing", "Allow the daemon to rewrite the temp routing config during the run") { options.learn_routing = true }
  opts.on("--max-tokens N", Integer, "Completion cap for each model edit response (default: 900)") { |value| options.max_tokens = value }
  opts.on("--timeout SECONDS", Integer, "Per-task polling timeout (default: 180)") { |value| options.timeout_seconds = value }
end

parser.parse!

abort "--tasks must be positive" unless options.tasks.positive?
abort "--tasks cannot exceed #{FIXTURES.length}" if options.tasks > FIXTURES.length
abort "--timeout must be positive" unless options.timeout_seconds.positive?
abort "--max-tokens must be positive" unless options.max_tokens.positive?
abort "routing config not found: #{options.routing_config}" unless File.file?(options.routing_config)
abort "agent helper not found: #{AGENT_PATH}" unless File.file?(AGENT_PATH)

ENV["RELAY_EVAL_MAX_TOKENS"] = options.max_tokens.to_s

EvalRunner.new(options).run
