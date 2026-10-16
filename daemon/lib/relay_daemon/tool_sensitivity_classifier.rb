# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module RelayDaemon
  # Denylist used by ApprovalSettingsStore::ASK_ON_SENSITIVE mode to decide
  # whether a pending Bash tool call needs a live approval round-trip, or can
  # be auto-approved. Deliberately conservative: only Bash calls are ever
  # classified (file-edit tools are already covered by the CLI's own
  # `acceptEdits` permission mode), and only a fixed set of risky command
  # patterns count as sensitive.
  module ToolSensitivityClassifier
    extend T::Sig

    SENSITIVE_COMMAND_PATTERNS = T.let(
      [
        /\brm\s+(-\w*r\w*f\w*|-\w*f\w*r\w*)\b/, # rm -rf / rm -fr (any flag order)
        /\bsudo\b/,
        /\bcurl\b[^|]*\|\s*(sh|bash|zsh)\b/,     # curl ... | sh
        /\bwget\b[^|]*\|\s*(sh|bash|zsh)\b/,     # wget ... | sh
        /\bgit\s+push\b[^\n]*--force\b/,
        /\bgit\s+reset\s+--hard\b/,
        /\bchmod\s+-R\b/,
        /\bdd\s+if=/,
        /\bmkfs(\.\w+)?\b/,
        /\b(curl|wget)\b/, # any outbound network fetch
        /\bnc\b|\bnetcat\b/
      ].freeze,
      T::Array[Regexp]
    )

    sig { params(tool_name: String, tool_input: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.sensitive?(tool_name, tool_input)
      return false unless tool_name == "Bash"

      command = tool_input["command"]
      return false unless command.is_a?(String)

      SENSITIVE_COMMAND_PATTERNS.any? { |pattern| pattern.match?(command) }
    end
  end
end
