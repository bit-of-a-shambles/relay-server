#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

BASE_URL = ENV.fetch("RELAY_E2E_BASE_URL", "http://127.0.0.1:17777")
TOKEN = ENV["RELAY_E2E_TOKEN"]
REPO_PATH = File.expand_path(ENV.fetch("RELAY_E2E_REPO_PATH", File.expand_path("../..", __dir__)))
PROMPT = ENV.fetch("RELAY_E2E_PROMPT", "Hello")
QUALITY_DIAL = Integer(ENV.fetch("RELAY_E2E_QUALITY_DIAL", "5"))
MODEL_OVERRIDE = ENV["RELAY_E2E_MODEL_OVERRIDE"]
LEARN_FROM_OUTCOME = ENV.fetch("RELAY_E2E_LEARN_FROM_OUTCOME", "true") == "true"
TEST_COMMAND = ENV.fetch("RELAY_E2E_TEST_COMMAND", "echo ok")
TIMEOUT_SECONDS = Integer(ENV.fetch("RELAY_E2E_TIMEOUT_SECONDS", "180"))

def request(method, path, token: nil, body: nil)
  uri = URI.join("#{BASE_URL}/", path.delete_prefix("/"))
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.read_timeout = 60

  req_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
  req = req_class.new(uri)
  req["Content-Type"] = "application/json"
  req["Authorization"] = "Bearer #{token}" if token
  req.body = JSON.generate(body) if body

  response = http.request(req)
  parsed = response.body.nil? || response.body.empty? ? nil : JSON.parse(response.body)
  [response.code.to_i, parsed]
end

def expect_success!(status, body, context)
  return body if (200..299).cover?(status)

  raise "#{context} failed with HTTP #{status}: #{body.inspect}"
end

def claim_token
  status, pair = request(:post, "/pair/start")
  pair = expect_success!(status, pair, "pair start")
  code = pair.fetch("qrPayload").fetch("pairingCode")

  status, claim = request(:post, "/pair/claim", body: { pairingCode: code })
  claim = expect_success!(status, claim, "pair claim")
  claim.fetch("authToken")
end

def ensure_repo(token)
  status, repo = request(:post, "/repos", token: token, body: {
    path: REPO_PATH,
    testCommand: TEST_COMMAND
  })
  return expect_success!(status, repo, "create repo") if status != 409

  status, repos = request(:get, "/repos", token: token)
  repos = expect_success!(status, repos, "list repos")
  repos.find { |candidate| candidate["path"] == REPO_PATH } ||
    raise("repo already registered but not returned by /repos: #{REPO_PATH}")
end

def wait_for_terminal_task(token, task_id)
  deadline = Time.now + TIMEOUT_SECONDS
  loop do
    status, task = request(:get, "/tasks/#{task_id}", token: token)
    task = expect_success!(status, task, "get task")
    return task if %w[needs_review failed approved rejected].include?(task.fetch("status"))

    raise "task #{task_id} timed out in status #{task.fetch("status")}" if Time.now > deadline

    sleep 2
  end
end

token = TOKEN || claim_token
repo = ensure_repo(token)
task_body = {
  repoId: repo.fetch("id"),
  prompt: PROMPT,
  qualityDial: QUALITY_DIAL,
  learnFromOutcome: LEARN_FROM_OUTCOME
}
task_body[:modelOverride] = MODEL_OVERRIDE if MODEL_OVERRIDE && !MODEL_OVERRIDE.empty?

status, task = request(:post, "/tasks", token: token, body: task_body)
task = expect_success!(status, task, "create task")

finished = wait_for_terminal_task(token, task.fetch("id"))
unless finished.fetch("status") == "needs_review" && finished["testsPassed"] == true
  raise "expected needs_review with passing tests, got #{finished.inspect}"
end

status, log = request(:get, "/tasks/#{task.fetch("id")}/log", token: token)
log = expect_success!(status, log, "get task log")
lines = log.fetch("lines")
raise "expected non-empty task log" if lines.empty?

puts JSON.pretty_generate({
  ok: true,
  taskId: task.fetch("id"),
  repoId: repo.fetch("id"),
  status: finished.fetch("status"),
  testsPassed: finished.fetch("testsPassed"),
  logLines: lines.length
})
