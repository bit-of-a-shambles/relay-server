# typed: true
# frozen_string_literal: true

require "open3"
require "sorbet-runtime"

module RelayDaemon
  # Thin typed wrapper around git CLI commands.
  # Always passes argument arrays to Open3 — never interpolates into a shell string.
  class Git
    extend T::Sig

    class GitError < StandardError; end

    sig { params(path: String).void }
    def initialize(path)
      @path = path
    end

    # Returns true when path looks like a git repo root.
    sig { returns(T::Boolean) }
    def repo?
      _out, _err, status = Open3.capture3("git", "-C", @path, "rev-parse", "--git-dir")
      T.must(status.success?)
    end

    # Returns the short name of the current branch (or detached HEAD SHA).
    sig { returns(String) }
    def current_branch
      out, _err, status = Open3.capture3("git", "-C", @path, "rev-parse", "--abbrev-ref", "HEAD")
      raise GitError, "git rev-parse failed in #{@path}" unless status.success?

      out.strip
    end

    # Returns the full SHA of HEAD.
    sig { returns(String) }
    def head_sha
      out, _err, status = Open3.capture3("git", "-C", @path, "rev-parse", "HEAD")
      raise GitError, "git rev-parse HEAD failed in #{@path}" unless status.success?

      out.strip
    end

    # Creates a worktree at +dest+ on a new branch named +branch+.
    sig { params(dest: String, branch: String).void }
    def worktree_add(dest, branch:)
      _, err, status = Open3.capture3(
        "git", "-C", @path, "worktree", "add", dest, "-b", branch
      )
      raise GitError, "git worktree add failed: #{err.strip}" unless status.success?
    end

    # Removes a worktree (prunes stale refs too).
    sig { params(dest: String).void }
    def worktree_remove(dest)
      _, err, status = Open3.capture3(
        "git", "-C", @path, "worktree", "remove", "--force", dest
      )
      raise GitError, "git worktree remove failed: #{err.strip}" unless status.success?

      Open3.capture3("git", "-C", @path, "worktree", "prune")
    end

    # Deletes a branch (force delete, safe for relay/* scratch branches).
    sig { params(branch: String).void }
    def delete_branch(branch)
      _, err, status = Open3.capture3("git", "-C", @path, "branch", "-D", branch)
      raise GitError, "git branch -D failed: #{err.strip}" unless status.success?
    end

    # Stages all changes in the working tree and commits with message.
    sig { params(message: String).void }
    def commit_all(message)
      Open3.capture3("git", "-C", @path, "add", "-A")
      _, err, status = Open3.capture3(
        "git", "-C", @path,
        "-c", "user.email=relay@local",
        "-c", "user.name=Relay",
        "-c", "commit.gpgsign=false",
        "commit", "--allow-empty", "-m", message
      )
      raise GitError, "git commit failed: #{err.strip}" unless status.success?
    end

    # Merges +branch+ into the currently checked-out branch (fast-forward
    # when possible, merge commit otherwise). On conflict the merge is
    # aborted (working tree restored) and GitError "merge_conflict" raised.
    sig { params(branch: String).void }
    def merge(branch)
      out, err, status = Open3.capture3(
        "git", "-C", @path,
        "-c", "user.email=relay@local",
        "-c", "user.name=Relay",
        "-c", "commit.gpgsign=false",
        "merge", "--no-edit", branch
      )
      unless status.success?
        combined = out + err
        if combined.include?("CONFLICT") || combined.include?("conflict")
          Open3.capture3("git", "-C", @path, "merge", "--abort")
          raise GitError, "merge_conflict"
        end

        raise GitError, "git merge failed: #{err.strip}"
      end
    end

    # Returns unified diff between +base_ref+...HEAD and +--numstat+ summary.
    sig { params(base_ref: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def diff_files(base_ref)
      numstat, _err, status = Open3.capture3(
        "git", "-C", @path, "diff", "--numstat", "#{base_ref}...HEAD"
      )
      return [] unless status.success?

      unified, = Open3.capture3(
        "git", "-C", @path, "diff", "#{base_ref}...HEAD"
      )

      parse_diff(numstat.strip, unified)
    end

    private

    sig { params(numstat: String, unified: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def parse_diff(numstat, unified)
      return [] if numstat.empty?

      # Split unified diff into per-file sections.
      file_diffs = unified.split(/(?=^diff --git )/)

      numstat.lines.filter_map do |line|
        parts = line.strip.split("\t")
        next unless parts.length == 3

        additions, deletions, file = parts
        patch = file_diffs.find { |d| d.include?("b/#{file}") } || ""
        {
          "file" => file,
          "unifiedDiff" => patch,
          "additions" => additions.to_i,
          "deletions" => deletions.to_i
        }
      end
    end
  end
end
