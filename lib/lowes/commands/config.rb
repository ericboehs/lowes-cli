module Lowes
  module Commands
    class Config
      def initialize(global)
        @global = global
      end

      def run(argv)
        action = argv.shift || "show"
        case action
        when "show"
          Lowes::Config.write_default!
          puts File.read(Lowes::Config.config_path)
          0
        when "edit"
          Lowes::Config.write_default!
          editor = ENV["VISUAL"] || ENV["EDITOR"] || "vi"
          system(editor, Lowes::Config.config_path.to_s) ? 0 : 1
        when "path"
          puts Lowes::Config.config_path
          0
        when "-h", "--help", "help"
          puts "Usage: lowes config [show|edit|path]"
          0
        else
          warn "unknown config action: #{action}"
          2
        end
      end
    end
  end
end
