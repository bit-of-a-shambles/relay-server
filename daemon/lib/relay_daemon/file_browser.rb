# frozen_string_literal: true

module RelayDaemon
  class FileBrowser
    def list(path:)
      current_path = normalize_path(path)
      raise ArgumentError, "path does not exist" unless File.exist?(current_path)
      raise ArgumentError, "path is not a directory" unless File.directory?(current_path)

      entries = Dir.children(current_path).filter_map do |name|
        entry_path = File.join(current_path, name)
        next unless File.directory?(entry_path)

        {
          "name" => name,
          "path" => File.expand_path(entry_path),
          "isDirectory" => true,
          "isGitRepo" => File.directory?(File.join(entry_path, ".git"))
        }
      rescue Errno::EACCES
        nil
      end

      {
        "path" => current_path,
        "parentPath" => parent_path(current_path),
        "isGitRepo" => File.directory?(File.join(current_path, ".git")),
        "entries" => entries.sort_by { |entry| entry["name"].downcase }
      }
    rescue Errno::EACCES
      raise ArgumentError, "permission denied"
    end

    private

    def normalize_path(path)
      raw = path.to_s.strip
      raw = "~" if raw.empty?
      File.expand_path(raw)
    end

    def parent_path(path)
      parent = File.dirname(path)
      parent == path ? nil : parent
    end
  end
end
