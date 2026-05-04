module Lowes
  module Commands
    class Materials
      def initialize(global)
        @global = global
      end

      def run(argv)
        action = argv.shift || "list"
        case action
        when "list"   then list(argv)
        when "add"    then add(argv)
        when "remove", "rm" then remove(argv)
        when "-h", "--help", "help"
          puts help_text
          0
        else
          warn "unknown materials action: #{action}"
          2
        end
      end

      private

      def list(_argv)
        Lowes::Config.load
        Lowes::Formatter.new(json: @global[:json]).materials(Lowes::Store.new.materials)
        0
      end

      def add(argv)
        entry = { "nickname" => nil, "url" => nil, "model" => nil, "item_id" => nil, "notes" => nil }
        while (a = argv.shift)
          case a
          when "--nickname" then entry["nickname"] = argv.shift
          when "--url"      then entry["url"]      = argv.shift
          when "--model"    then entry["model"]    = argv.shift
          when "--item-id"  then entry["item_id"]  = argv.shift
          when "--notes"    then entry["notes"]    = argv.shift
          else
            # Positional — guess what kind it is
            if a.start_with?("http://", "https://")
              entry["url"] ||= a
            elsif a.match?(/\A\d{6,}\z/)
              entry["item_id"] ||= a
            else
              entry["model"] ||= a
            end
          end
        end
        entry.compact!

        if [entry["url"], entry["model"], entry["item_id"]].compact.empty?
          warn "materials add: need at least --url, --model, or --item-id"
          return 2
        end

        Lowes::Config.load
        Lowes::Store.new.add_material(entry)
        warn "added: #{entry["nickname"] || entry["model"] || entry["item_id"] || entry["url"]}"
        0
      end

      def remove(argv)
        key = argv.shift
        unless key
          warn "materials remove: key required (nickname, model, item-id, or url)"
          return 2
        end
        Lowes::Config.load
        n = Lowes::Store.new.remove_material(key)
        warn(n.positive? ? "removed #{n}" : "no match for #{key}")
        n.positive? ? 0 : 1
      end

      def help_text
        <<~HELP
          Usage: lowes materials <list|add|remove> [options]

          add:
            lowes materials add [URL|MODEL|ITEM-ID]
              [--nickname NAME] [--url URL] [--model M] [--item-id ID] [--notes ...]

          remove:
            lowes materials remove <nickname|model|item-id|url>

          list:
            lowes materials list [--json]
        HELP
      end
    end
  end
end
