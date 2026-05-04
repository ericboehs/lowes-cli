require "pathname"
require "optparse"

module Lowes
  class CLI
    COMMANDS = %w[chrome-start web login sync list show search config price prices materials quotes store help].freeze

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      argv = argv.dup
      global = parse_global!(argv)
      cmd = argv.shift || "help"

      case cmd
      when "help", "-h", "--help"
        puts help_text
        return 0
      when "chrome-start" then Commands::ChromeStart.new(global).run(argv)
      when "web"       then Commands::Web.new(global).run(argv)
      when "login"     then Commands::Login.new(global).run(argv)
      when "sync"      then Commands::Sync.new(global).run(argv)
      when "list"      then Commands::List.new(global).run(argv)
      when "show"      then Commands::Show.new(global).run(argv)
      when "search"    then Commands::Search.new(global).run(argv)
      when "config"    then Commands::Config.new(global).run(argv)
      when "price"     then Commands::Price.new(global).run(argv)
      when "prices"    then Commands::Prices.new(global).run(argv)
      when "materials" then Commands::Materials.new(global).run(argv)
      when "quotes"    then Commands::Quotes.new(global).run(argv)
      when "store"     then Commands::Store.new(global).run(argv)
      else
        warn "unknown command: #{cmd}"
        warn help_text
        2
      end
    rescue Worker::Error, RuntimeError => e
      warn "lowes: #{e.message}"
      1
    end

    private

    def parse_global!(argv)
      opts = { json: false, quiet: false, verbose: false }
      keep = []
      while (a = argv.shift)
        case a
        when "--json"           then opts[:json] = true
        when "-q", "--quiet"    then opts[:quiet] = true
        when "-v", "--verbose"  then opts[:verbose] = true
        else
          keep << a
        end
      end
      argv.replace(keep)
      opts
    end

    def help_text
      <<~HELP
        Usage: lowes <command> [options]

        Commands:
          chrome-start  Launch real Chrome with remote-debugging so other commands can attach
          web        Browse cached data in a local Sinatra UI (default :4567)
          login      Open a browser so you can sign in (handles captcha/2FA)
          sync       Pull recent orders from Lowe's into local store
          list       List orders from local store
          show       Show one order in detail
          search     Search orders by item title / model / order id
          price      Check current price for a product URL or model number
          prices     Sync current prices for all tracked materials
          materials  Manage tracked materials list (add/list/remove)
          quotes     List or show saved quotes
          store      Show current Lowe's store, or set it (`lowes store 73703`)
          config     Show or edit config
          help       Show this help

        Global flags:
          --json       Emit JSON instead of formatted output
          -q/--quiet   Suppress non-essential output
          -v/--verbose Verbose worker logs

        Run `lowes <command> --help` for command-specific options.
      HELP
    end
  end
end
