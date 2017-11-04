require 'fileutils'
require 'set'
require 'open-uri'
require 'yaml'

require 'chronic'
require 'chronic_duration'

require 'oj'
require 'multi_json'

require 'discordrb'

require 'pry'
#require 'fuzzy_match'

def get_value_from_arguments(option_name: nil, env_key:nil, default:)
  if option_name && option_index = ARGV.index(option_name)
    ARGV.delete_at(option_index)
    abort("Command line option '#{option_name}' should be followed by a another argument.") unless option_value = ARGV.delete_at(option_index)
    return option_value
  elsif env_key && ENV[env_key]
    return ENV[env_key]
  else
    return default
  end
end

DEFAULT_CONFIG = YAML.load_file(get_value_from_arguments(option_name: '--default-config', default:'./default_config.yaml')).freeze

def config_keys_changed_from_defaults?(loaded_config)
  loaded_config.keys.size != DEFAULT_CONFIG.keys.size || loaded_config.keys.sort != DEFAULT_CONFIG.keys.sort
end

def config
  return @config if @config

  source_file = get_value_from_arguments(option_name: '--config-file', env_key: 'DISCORD_BOT_CONFIG_FILE', default: './.config.json')
  unless @config = load_config(source_file: source_file)
    save_config(source_file: source_file, config: DEFAULT_CONFIG)
    abort("Your config was empty. I've generated a valid configuration in its placed based on our defaults. Please edit (#{source_file}) and restart")
  end

  @config
end

def compare_config_to_defaults(loaded_config)
  msg = <<~CONFIG_EOS
    Keys missing from loaded config:
    #{DEFAULT_CONFIG.keys - loaded_config.keys}

    Keys extra compared to DEFAULT_CONFIG:
    #{loaded_config.keys - DEFAULT_CONFIG.keys}

    DEFAULT_CONFIG:
    #{MultiJson.dump(DEFAULT_CONFIG, pretty: true)}

    Loaded Config:
    #{MultiJson.dump(loaded_config, pretty: true)}

    Suggested Merge:
    #{MultiJson.dump(DEFAULT_CONFIG.merge(loaded_config), pretty: true)}
  CONFIG_EOS
end

def load_config(source_file: )
  source_file = File.expand_path(source_file)
  return nil unless File.exist?(source_file)
  loaded_config = MultiJson.load(open(source_file))
  abort("Loaded config does not contain the same amount of keys as the default config. Please your config with the default config, make the appropriate changes, and try again.\n" + compare_config_to_defaults(loaded_config)) if config_keys_changed_from_defaults?(loaded_config)
  loaded_config
end

def save_config(source_file:, config:, pretty_print: true, backup: false)
  source_file = File.expand_path(source_file)
  FileUtils.cp(source_file, source_file + DateTime.now.strftime(".%Y%m%d%H%M%S")) if backup #TODO: Allow for different backup methods (git?)
  begin
    content = MultiJson.dump(config, pretty: pretty_print)
  rescue RuntimeError => e
    puts "Error while trying to dump config:\n#{config}\n#{e.message}"
    raise e
  else
    write_file(source_file: source_file, content: content)
  end
  config
end

def write_file(source_file:, content:)
  File.open(source_file,'w+') do |f|
    f.puts(content)
  end
end

def channels(*filters)
  return config['channels'].map{|type, channels| channels}.flatten.uniq if filters.delete('all')
  channels = []
  filters.each do |filter|
    channels += config['channels'][filter] if config['channels'].has_key?(filter)
  end
  return channels.uniq
end

EVENTS_SOURCE = File.expand_path(get_value_from_arguments(option_name: '--events_source', env_key: 'EVENTS_SOURCE', default: 'events.json')).freeze
ENV['TZ'] = get_value_from_arguments(option_name: '--timezone', env_key: 'TZ', default: 'UTC').freeze # Chronic uses ENV['TZ'] for its timezone.
DISCORD_TOKEN = get_value_from_arguments(option_name: '--discord-token', env_key: 'DISCORD_BOT_TOKEN', default: nil).freeze
DISCORD_CLIENT_ID = get_value_from_arguments(option_name: '--discord-client-id', env_key: 'DISCORD_BOT_CLIENT_ID', default: nil).freeze
REGEX_UPGRADE_CALCULATOR = /(upgrade:?|will it finish in time\??) (?<duration>((?<days>\d+)d ?)?(?<hours>\d+):(?<minutes>\d+):(?<seconds>\d+))(?<timer_help> (?<base_number_helps>\d+)\+(?<bonus_number_helps>\d+) (?<base_timer_help_duration>\d+)\+(?<bonus_timer_help_duration>\d+))?(?<next_event> -next>)?(?<restrict_type> GE-only)?/i.freeze
REGEX_SPEEDUPS = /how long are (?<m5>\d+)[: ](?<h1>\d+)[: ](?<h3>\d+) speedups\??/i.freeze
REGEX_WALL_CALCULATOR = /!wall(?<duration> (?:(?<days>\d)d ?)?(?<hours>\d+):(?<minutes>\d+):(?<seconds>\d+)?)?(?<wall_defense> (?<current_wall_defense>\d+)(?:\/(?<max_wall_defense>\d+))?)?/i.freeze
REGEX_GET_ALLIANCE_PORTAL = /^(?:!(alliance )?portal|when(?:'| i)s (?:(?<alliance_tag>#{config['alliances'].keys.join('|')}) )?(?:alliance )?portal|(?:(?<alliance_tag>#{config['alliances'].keys.join('|')}) )?(?:alliance )?portal soon\?)/i.freeze
REGEX_GET_FALLEN_KNIGHTS = /^(?:!fallen( knights)?|when(?:'| i)s (?:(?<alliance_tag>#{config['alliances'].keys.join('|')}) )?fallen(?: knights)?|(?:(?<alliance_tag>#{config['alliances'].keys.join('|')}) )?fallen(?: knights)? soon\?)/i.freeze
REGEX_SET_ALLIANCE_PORTAL = /^!set (?:(?<alliance_tag>#{config['alliances'].keys.join('|')}) )?(?:alliance )?portal (?<content>.+)$/i.freeze
REGEX_SET_FALLEN_KNIGHTS = /^!set (?:(?<alliance_tag>#{config['alliances'].keys.join('|')}) )?(?:fallen|fallen knights|fk) (?<content>.+)$/i.freeze
REGEX_SET_GOLEM = /^!set (?<keyword>golem|kingdom threat) (?<content>.+)$/i.freeze
WALL_DMG_PER_MINUTE = (4.0).freeze
WALL_BURNING_DURATION_PER_HIT = ChronicDuration.parse('30 minutes').freeze
REPOSITORY_URL = "https://github.com/BeardBrewery/DiscordBot-KoA"
GOLD_EVENT_INTERVAL = '2 weeks from now'.freeze
ALLIANCE_EVENT_INTERVAL = '5 weeks from now'.freeze

# This statement creates a bot with the specified token and application ID. After this line, you can add events to the
# created bot, and eventually run it.
#
# If you don't yet have a token and application ID to put in here, you will need to create a bot account here:
#   https://discordapp.com/developers/applications/me
# If you're wondering about what redirect URIs and RPC origins, you can ignore those for now. If that doesn't satisfy
# you, look here: https://github.com/meew0/discordrb/wiki/Redirect-URIs-and-RPC-origins
# After creating the bot, simply copy the token (*not* the OAuth2 secret) and the client ID and put it into the
# respective places.
bot = Discordrb::Bot.new token: DISCORD_TOKEN, client_id: DISCORD_CLIENT_ID.to_i

if ARGV.delete('--invite-url')
  puts "This bot's invite URL is #{bot.invite_url}."
  puts 'Click on it to invite it to your server.'
end

module JoinAnnouncer
  extend Discordrb::EventContainer

  member_join do |bot_event|
    bot_event.server.general_channel.send_message(config['join_announcer']['welcome_message'] % {user_mention: bot_event.user.name})
  end
end

def scheduled_events(clear_cache: false, include_expired: false, restrict_types: [], names: [], sort: :time, bot_event: nil, include_private: false)
	if clear_cache || @scheduled_events.nil? || @scheduled_events[:cached] < Chronic.parse('2 hours ago')
		bot_event.respond "Scheduled Events cache cleared at request of #{bot_event.user.mention}!" if bot_event && clear_cache
		@scheduled_events = {cached: Time.now}.merge(MultiJson.load(open(EVENTS_SOURCE)))
		@scheduled_events['events'].each {|scheduled_event| scheduled_event[:time] = Chronic.parse(scheduled_event['ISO8601']) unless scheduled_event.has_key?(:time)}
	end

	events = @scheduled_events['events'].dup

	events.reject!{|scheduled_event|(scheduled_event[:time] - Time.now).to_i < 0} unless include_expired

	unless restrict_types.empty?
		restrict_types.map!{|type|type.downcase}
		events.select!{|scheduled_event|next unless scheduled_event.has_key?('type'); restrict_types.include?(scheduled_event['type'].downcase)}
	end 

  unless include_private
    events.reject!{|scheduled_event|scheduled_event['private']}
  end

	unless names.compact.empty?
		names.map!{|name|name.downcase}
		events.select!{|scheduled_event|next unless scheduled_event.has_key?('name'); names.include?(scheduled_event['name'].downcase)}
	end

	if sort == :time
		events.sort_by! do |scheduled_event|
			scheduled_event['ISO8601']
		end
	end

	return events
end

def check_confirmed(target_event, msg)
	msg += " Mind you, this time has not yet been confirmed, so it might change." if (target_event['status'].downcase == 'unconfirmed' rescue false)
	msg
end

def time_difference(target_event, format: :textual)
  difference_in_seconds = target_event[:time].to_i - Time.now.to_i
  return difference_in_seconds if format == :seconds
	ChronicDuration.output(difference_in_seconds)
end

def help_vars(bot_event)
  {
    user_mention: bot_event.user.mention, 
    first_alliance_tag: config['alliances'].keys.first, 
    first_alliance_name: config['alliances'].values.first, 
    last_alliance_tag: config['alliances'].keys.last, 
    last_alliance_name: config['alliances'].values.last,
    TZ: ENV['TZ'],
  }
end

bot.message(start_with: '!help') do |bot_event|
  msg = open('help_general.md').read % help_vars(bot_event)
  bot_event.respond(msg) 
end

bot.message(start_with: '!calculators') do |bot_event|
  msg = open('help_calculators.md').read % help_vars(bot_event)
  bot_event.respond(msg) 
end

bot.message(start_with: '!admin') do |bot_event|
  if bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
    msg = open('help_admin.md').read % help_vars(bot_event)
  else
    msg = "#{bot_event.user.mention}, you don't have access to this command"
  end
  bot_event.respond(msg)
end

bot.message(start_with: '!find ') do |bot_event|
	begin
		needle = bot_event.content.gsub(/!find /,'')
		messages = bot_event.channel.history(100).select {|message| message.content.include?(needle)}
	rescue
		binding.pry
	end
	begin
		bot_event.respond "#{bot_event.user.mention}: Found #{messages.reverse[0...5].count} results: #{messages.join("\n")[0...1800]}"
	rescue
		binding.pry
	end
end

def alliance_portal_event(bot_event:, clear_cache: false, alliance: config['alliances'].keys.first.downcase)
  event_key = alliance + '-portal'
	target_event = scheduled_events(names: [config['events_map'][event_key]], include_expired: false, sort: :time, bot_event: bot_event, clear_cache: clear_cache, include_private: true).first
	announce_event(bot_event: bot_event, clear_cache: clear_cache, target_event: target_event, event_name: config['events_map'][event_key])
end

def fallen_knights_event(bot_event:, clear_cache: false, alliance: config['alliances'].keys.first.downcase)
  event_key = alliance + ' fallen knights'
  unless event_name = config['events_map'][event_key]
    bot_event.respond "#{bot_event.user.mention}: I don't know this alliance event ('No events map match for #{event_key}')"
  else
    target_event = scheduled_events(names: [event_name], include_expired: false, sort: :time, bot_event: bot_event, clear_cache: clear_cache, include_private: true).first
    announce_event(bot_event: bot_event, clear_cache: clear_cache, target_event: target_event, event_name: event_name)
  end
end

def golem_event(bot_event:, clear_cache: false)
	target_event = scheduled_events(names: [config['events_map']['golem']], include_expired: false, sort: :time, bot_event: bot_event, clear_cache: clear_cache).first
	announce_event(bot_event: bot_event, clear_cache: clear_cache, target_event: target_event, event_name: config['events_map']['golem'])
end

def announce_event(bot_event:, clear_cache: false, target_event:, event_name: nil)
	if target_event
		msg = "#{bot_event.user.mention}: The #{target_event['name']} event is currently scheduled for #{target_event[:time]}, which is in about #{time_difference(target_event)}."
		bot_event.respond check_confirmed(target_event, msg)
	else
		bot_event.respond "Sorry #{bot_event.user.mention}, there's currently no next #{event_name} scheduled yet. Maybe check the event centre?"
	end
end

def next_event(bot_event:, clear_cache: false)
	if target_event = scheduled_events(include_expired: false, sort: :time, clear_cache: clear_cache, include_private: include_private?(bot_event)).first
		msg = "#{bot_event.user.mention}: Next event is #{target_event['name']} and is currently scheduled for #{target_event[:time]}, which is in about #{time_difference(target_event)}."
    msg += "\nThis does not include private alliance events as this is a public channel." unless include_private?(bot_event)
		bot_event.respond check_confirmed(target_event, msg)
	else
		bot_event.respond "Sorry #{bot_event.user.mention}, there's currently no next event scheduled yet."
	end
end

def set_event(bot_event:, event_key:, content:, event_type:)
	unless bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
		bot_event.respond "#{bot_event.user.mention} you don't have access to this command"
	else
    confirmed = !content.gsub!(/\s-unconfirmed/,'')
    event_time = content

  	events = MultiJson.load(open(EVENTS_SOURCE))
  	target_event = events['events'].find do |event|
  	  event['name'] == config['events_map'][event_key]
  	end
  	if target_event.nil? || target_event.empty?
      if target_event = config['template_events'][event_type]
        target_event['name'] = config['events_map'][event_key]
        events['events'] << target_event
      else
        bot_event.respond "#{bot_event.user.mention}, I could not find an '#{event_key}'-event called '#{config['events_map'][event_key]}', nor could I find a template for it."
        return false
      end
  	end

  	begin
  		target_event['ISO8601'] = Chronic.parse(event_time).iso8601
  	rescue
  		bot_event.respond "#{bot_event.user.mention}, I'm sorry, but '#{event_time}' is not recognised as a valid time."
  		return false
  	end
  	target_event.delete('status')
  	target_event['status'] = 'unconfirmed' unless confirmed
    store_events(events)
  end
end

def store_events(events=nil)
  if events.nil?
    return false unless scheduled_events(clear_cache: true, include_expired: true, sort: :time, include_private: true)
    events = @scheduled_events
  end
  events.delete(:cached)
  events['events'].each do |event|
    if event[:time]
      event['ISO8601'] = event[:time].iso8601
      event.delete(:time)
    end
  end

  save_config(source_file: EVENTS_SOURCE, config: events, pretty_print: true, backup: true)

  #Force a cache clear:
  @scheduled_events = nil
end

bot.message(start_with: REGEX_GET_ALLIANCE_PORTAL, in: channels('alliance', 'control')) do |bot_event|
  	clear_cache = bot_event.content.include?('clearcache') && bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
    md = bot_event.content.match(REGEX_GET_ALLIANCE_PORTAL)
    alliance_tag = md['alliance_tag'] || config['alliances'].keys.first
  	alliance_portal_event(bot_event: bot_event, clear_cache: clear_cache, alliance: alliance_tag.downcase)
end

bot.message(start_with: REGEX_GET_FALLEN_KNIGHTS, in:  channels('alliance', 'control')) do |bot_event|
  	clear_cache = bot_event.content.include?('clearcache') && bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
    md = bot_event.content.match(REGEX_GET_FALLEN_KNIGHTS)
    alliance_tag = md['alliance_tag'] || config['alliances'].keys.first
  	fallen_knights_event(bot_event: bot_event, clear_cache: clear_cache, alliance: alliance_tag.downcase)
end

bot.message(start_with: '!golem', in:  channels('all')) do |bot_event|
  	clear_cache = bot_event.content.include?('clearcache') && bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
  	golem_event(bot_event: bot_event, clear_cache: clear_cache)
end

bot.message(content: REGEX_SET_ALLIANCE_PORTAL, in:  channels('alliance', 'control')) do |bot_event|
  md = bot_event.content.match(REGEX_SET_ALLIANCE_PORTAL)
  alliance_tag = md['alliance_tag'] || config['alliances'].keys.first

	set_event(bot_event: bot_event, event_type: 'portal', event_key: "#{alliance_tag}-portal", content: md['content'])
	alliance_portal_event(bot_event: bot_event, clear_cache: true, alliance: alliance_tag)
end

bot.message(content: REGEX_SET_FALLEN_KNIGHTS, in: channels('alliance', 'control')) do |bot_event|
  md = bot_event.content.match(REGEX_SET_FALLEN_KNIGHTS)
  alliance_tag = md['alliance_tag'] || config['alliances'].keys.first

	set_event(bot_event: bot_event, event_type: 'fallen knights', event_key: "#{alliance_tag} fallen knights", content: md['content'])
	fallen_knights_event(bot_event: bot_event, clear_cache: true, alliance: alliance_tag)
end

bot.message(content: REGEX_SET_GOLEM, in: channels('all')) do |bot_event|
  md = bot_event.content.match(REGEX_SET_GOLEM)
	set_event(bot_event: bot_event, event_type: 'golem', event_key: 'golem', content: md['content'])
	golem_event(bot_event: bot_event, clear_cache: true)
end

bot.message(start_with: ['rally rounds?'], in: channels('alliance', 'control')) do |bot_event|
  bot_event.respond "Fallen Knights Rally Rounds are at 7, 14 and 17, with Fort at rounds 10 and 20. Only those who already have high *individual* ranks are supposed to go into the fort"
end

bot.message(start_with: ['!next event', /(what|when)('s| is) next event/], in: channels('all')) do |bot_event|
	clear_cache = bot_event.content.include?('clearcache') && bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
	next_event(bot_event: bot_event, clear_cache: clear_cache)
end

bot.message(start_with: [REGEX_SPEEDUPS], in: channels('spam', 'control')) do |bot_event|
  md = bot_event.content.match(REGEX_SPEEDUPS).named_captures
  md.each do |k,v|
    md[k] = v.to_i
  end
  msg =<<~BOTRESPONSE
    #{bot_event.user.mention}:
    #{md['m5']} x 5m = #{ChronicDuration.output(md['m5'] * 5 * 60)}
    #{md['h1']} x 1h = #{ChronicDuration.output(md['h1'] * 60 * 60)}
    #{md['h3']} x 3h = #{ChronicDuration.output(md['h3'] * 3 * 60 * 60)}
    = #{ChronicDuration.output((((md['h3'] * 3) + md['h1']) * 60 * 60) + (md['m5'] * 5 * 60))}
  BOTRESPONSE
  bot_event.respond msg
end

bot.message(start_with: [REGEX_UPGRADE_CALCULATOR], in: channels('spam', 'control')) do |bot_event|
  clear_cache = bot_event.content.include?('clearcache') && bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
  restrict_types = (bot_event.content.gsub!(/ GE-only/i, '') ? ['Gold Event'] : [])
  index = (bot_event.content.gsub!(/ -next/i, '') ? 1 : 0)
  upgrade_calculator(bot_event, restrict_types: restrict_types, index: index)
end

def upgrade_calculator(bot_event, format: :default, restrict_types: [], index: 0)
  events = scheduled_events(clear_cache: false, include_expired: false, names: ['Upgrade Stage'], restrict_types: restrict_types, sort: :time, bot_event: nil)
  event = events[index]
  #TODO: Loop through all events to check which event is the closest.
  time_till_upgrade_stage = time_difference(event, format: :seconds)
  md = bot_event.content.match(REGEX_UPGRADE_CALCULATOR)
  unless md
    bot_event.respond "Could not match your message against the expected format 1d 12:59:59 10+9 60+9"
    binding.pry
  else
    upgrade_seconds = ChronicDuration.parse(md['duration'].strip)
    total_timer_help = 0
    if md['timer_help']
      total_timer_help = (md['base_number_helps'].to_i + md['bonus_number_helps'].to_i) * (md['base_timer_help_duration'].to_i + md['bonus_timer_help_duration'].to_i)
    end
    total_upgrade_seconds = upgrade_seconds - total_timer_help
    time_difference = (total_upgrade_seconds - time_till_upgrade_stage)

    speedups = {start_of_stage: {'3h' => 0, '1h' => 0, '5m' => 0, 'remainder' => 0}, end_of_stage: {'3h' => 0, '1h' => 0, '5m' => 0, 'remainder' => 0}}
    if time_difference > 0
      speedups[:start_of_stage]['3h'], remainder = (time_difference).divmod(60*60*3)
      speedups[:start_of_stage]['1h'], remainder = remainder.divmod(60*60)
      speedups[:start_of_stage]['5m'], speedups[:start_of_stage]['remainder'] = remainder.divmod(60*5)

      speedups[:end_of_stage]['3h'], remainder = (time_difference - (24*60*60)).divmod(60*60*3)
      speedups[:end_of_stage]['1h'], remainder = remainder.divmod(60*60)
      speedups[:end_of_stage]['5m'], speedups[:end_of_stage]['remainder'] = remainder.divmod(60*5)
    end

    if format == :default
      msg=<<~BOTRESPONSE
        #{bot_event.user.mention}:

        Your Upgrade will take:
        ***#{ChronicDuration.output(total_upgrade_seconds)}***

      BOTRESPONSE

      if total_timer_help == 0
        msg+="No timer help to deduct.\n\n"
      else
        msg+=<<~BOTRESPONSE
          Time deducted for timer help:
          **#{ChronicDuration.output(total_timer_help)}**

        BOTRESPONSE
      end

      msg+=<<~BOTRESPONSE      
        Till next #{event['type']} Upgrade Stage:
        ***#{ChronicDuration.output(time_till_upgrade_stage)}***

        It will finish:
        ***#{ChronicDuration.output(time_difference.abs)}***
        #{time_difference > 0 ? '***after*** the stage has started! :clap: YAY! :D' : '***too soon*** :cry: Wait a bit, or try without your construction speed boosting equipment and/or heroes?'}

      BOTRESPONSE
    elsif format == :compact
      msg=<<~BOTRESPONSE
        #{bot_event.user.mention}:
        ***#{ChronicDuration.output(total_upgrade_seconds)}*** for your upgrade to finish after **#{ChronicDuration.output(total_timer_help)||'no'}** total timer help has been deducted.
        ***#{ChronicDuration.output(time_till_upgrade_stage)}*** till the next upgrade stage.
  
        It will finish ***#{ChronicDuration.output(time_difference.abs)}*** #{time_difference > 0 ? '***after*** the stage has started! :clap: YAY! :D' : '***too soon*** :cry: Wait a bit, or try without your construction speed boosting equipment and/or heroes?'}
      BOTRESPONSE
    else
      msg='UNDEFINED FORMAT'
    end

    if time_difference > 0
      if time_difference >= (24 * 60 * 60)
        msg += "It will take longer than 24 hours though, so unless you have enough speedups, it will finish **after the upgrade stage has ended** :cry:\n\n"
        msg += "Speedups needed to finish it before the end of the stage:\n**#{speedups[:end_of_stage]['3h']}** x 3h\n**#{speedups[:end_of_stage]['1h']}** x 1h\n**#{speedups[:end_of_stage]['5m']}** x 5m\nRemaining:#{speedups[:end_of_stage]['remainder'].divmod(60).join(' minutes ')} seconds. If there's a remainder, you need another 5m speedup at the very least.\n\n"
      end
      msg += "Speedups needed to finish it at the start of the stage:\n**#{speedups[:start_of_stage]['3h']}** x 3h\n**#{speedups[:start_of_stage]['1h']}** x 1h\n**#{speedups[:start_of_stage]['5m']}** x 5m\nRemaining:#{speedups[:start_of_stage]['remainder'].divmod(60).join(' minutes ')} seconds\n\n"
    end

    msg +=<<~BOTRESPONSE
      Please note that this is based on the calculation:
        (#{upgrade_seconds} - (#{md['base_number_helps'].to_i} + #{md['bonus_number_helps'].to_i}) * (#{md['base_timer_help_duration'].to_i} + #{md['bonus_timer_help_duration'].to_i})) - #{time_till_upgrade_stage}) = #{time_difference} seconds.
        Or: 
        (#{md['duration']} base upgrade time - (#{md['base_number_helps'].to_i} + #{md['bonus_number_helps'].to_i} number of timer helps) * (#{md['base_timer_help_duration'].to_i} + #{md['bonus_timer_help_duration'].to_i} = #{ChronicDuration.output(md['base_timer_help_duration'].to_i + md['bonus_timer_help_duration'].to_i)} timer help duration) = #{ChronicDuration.output(total_upgrade_seconds)} upgrade time) - #{ChronicDuration.output(time_till_upgrade_stage)} till upgrade stage ) = #{ChronicDuration.output(time_difference)} seconds.

      Also, be careful to not accidentally trigger the Instant Building Speedup if there's not a lot of margin between the start of the stage and the remaining construction time.
      Don't blame me if it finishes too soon! ;-) 
    BOTRESPONSE
    bot_event.respond msg
    bot_event.respond "THIS DOES NOT INCLUDE YOUR TIMER HELP DURATION! Please specify base number of timer helps + bonus number of timer helps and base timer help duration and bonus timer help duration in the format: 20+9 60+10. For example: \"will it finish in time? 1d 21:18:10 20+9 88+9\". You can find this info in your Embassy info screen." unless md['timer_help']
  end
end

bot.message(start_with: ['!reschedule gold event', '!reschedule alliance event'], in: channels('all')) do |bot_event|
  unless bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
    bot_event.respond("#{bot_event.user.mention}: you're not authorised to reschedule this event")
  else
    msg = ""
    md = bot_event.content.match(/!reschedule (?<event_type>gold|alliance) event/i)
    event_type = md['event_type'].capitalize + ' Event'
    interval = GOLD_EVENT_INTERVAL
    interval = ALLIANCE_EVENT_INTERVAL if event_type == 'Alliance Event'
    events = scheduled_events(clear_cache: false, include_expired: true, restrict_types: [event_type], sort: :time, bot_event: bot_event)
    events.each do |event|
      old_time = event[:time]
      event[:time] = Chronic.parse(interval, now: old_time)
      event['ISO8601'] = event[:time].iso8601
      msg += "Rescheduling #{event['name']} from #{old_time} to #{event[:time]}\n"
    end
    store_events(@scheduled_events)
    split_message(msg).each do |split_msg|
      bot_event.respond(split_msg)
    end
  end
end

def split_message(msg, max_msg_size=1950)
	return [msg] if msg.size <= max_msg_size
	split_msg = []
	msg.split(/\n/).each do |sentence|
		current_msg = ''
		sentence.split.each do |word|
			if current_msg.size + word.size > max_msg_size
				current_msg += '[...]'
				split_msg << current_msg
				current_msg = ''
			end
			current_msg += " #{word}"
			current_msg.strip
		end
		split_msg << current_msg
	end
	return split_msg
end

def include_private?(bot_event)
  channels('alliance', 'control').map{|c|c.downcase}.include?('#' + bot_event.channel.name.to_s.downcase)
end


bot.message(start_with: /!next \d+ events/, in: channels('all')) do |bot_event|
	clear_cache = bot_event.content.include?('clearcache') && bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
	amount = bot_event.content.match(/!next (\d+) events/)[1].to_i
	amount = 1 if amount <= 0
	amount = 10 if amount > 10

	upcoming_events = scheduled_events(include_expired: false, sort: :time, clear_cache: clear_cache, include_private: include_private?(bot_event))[0,amount]
	unless upcoming_events.empty?
		msg = "#{bot_event.user.mention}: I found #{upcoming_events.count} events:\n"
		upcoming_events.each do |target_event|
      prefix = ''
      prefix = '[AE] ' if target_event['type'] == 'Alliance Event'
      prefix = '[GE] ' if target_event['type'] == 'Gold Event'
			msg += "\n#{prefix}#{target_event['name']}: #{target_event[:time]} (about #{time_difference(target_event)} from now)."
			msg += " [UNCONFIRMED]" if target_event['status'] == 'unconfirmed' rescue false
			msg += "\n"
		end
    msg += "\nThis does not include private alliance events as this is a public channel." unless include_private?(bot_event)
		split_message(msg, 1950).each do |msg|
			bot_event.respond msg
		end
	else
		bot_event.respond "Sorry #{bot_event.user.mention}, there's currently no next event scheduled yet."
	end
end

bot.message(start_with: ['!next stage', /(what|when)('s| is) next stage/, /what stage('s| is) next/], in: channels('all')) do |bot_event|
  	clear_cache = bot_event.content.include?('clearcache') && bot_event.user.roles.any?{|role|['R4', 'R5'].include?(role.name)}
	grouped_events = scheduled_events(include_expired: false, sort: :time, restrict_types: ['Gold Event', 'Alliance Event'], clear_cache: clear_cache).group_by{|scheduled_event|scheduled_event['type']}
	grouped_events.each do |event_type, events|
		if target_event = events.first
			msg = "#{bot_event.user.mention}: Next #{event_type} stage is #{target_event['name']} and is currently scheduled for #{target_event[:time]}, which is in about #{time_difference(target_event)}."
			bot_event.respond check_confirmed(target_event, msg)
		else
			bot_event.respond "Sorry #{bot_event.user.mention}, there's currently no next #{event_type} stage scheduled yet."
		end
	end
end

bot.message(start_with: [REGEX_WALL_CALCULATOR], in: channels('spam', 'control')) do |bot_event|
  md = bot_event.content.match(REGEX_WALL_CALCULATOR)
  msg = "#{bot_event.user.mention},\n"
  if md['wall_defense']
    seconds_to_zero_current_wall_defense = md['current_wall_defense'].to_i / WALL_DMG_PER_MINUTE * 60
    nr_of_hits_to_zero_current_wall_defense = seconds_to_zero_current_wall_defense / 60 / 30

    seconds_to_zero_max_wall_defense = md['max_wall_defense'].to_i / WALL_DMG_PER_MINUTE * 60 rescue nil
    nr_of_hits_to_zero_max_wall_defense = seconds_to_zero_max_wall_defense / 60 / 30 rescue nil

    msg += "Your wall's #{md['current_wall_defense'].to_i} *current* defense will reach zero in about #{nr_of_hits_to_zero_current_wall_defense.ceil} hits, which will keep it burning for #{ChronicDuration.output(seconds_to_zero_current_wall_defense)}.\n\n"

    msg += "Your wall's #{md['max_wall_defense'].to_i} *max* defense will reach zero in about #{nr_of_hits_to_zero_max_wall_defense.ceil} hits, which will keep it burning for #{ChronicDuration.output(seconds_to_zero_max_wall_defense)}.\n\n" if seconds_to_zero_max_wall_defense

  end

  if md['duration']
    duration = ChronicDuration.parse(md['duration'])
    total_damage_over_time = ((duration / 60) * WALL_DMG_PER_MINUTE).to_i
    msg += "Your wall will take ***#{total_damage_over_time} damage*** in total over the #{ChronicDuration.output(duration)} of burning.\n"
    if md['wall_defense']
      if seconds_to_zero_current_wall_defense <= duration
        msg += "Your wall's current defenses will reach zero in #{ChronicDuration.output(seconds_to_zero_current_wall_defense)} if you don't stop it from burning.\n"
      else
        msg += "It looks like your wall would survive the burning. After it's finished burning, it will have #{md['current_wall_defense'].to_i - total_damage_over_time} defense points left.\n"
      end
    end
  end
  bot_event.respond msg
end

bot.message(content: '!about') do |bot_event|
  bot_event.respond "This bot is created by FiXato (https://profile.fixato.org), and uses meew0's discordrb bot framework (https://github.com/meew0/discordrb), as well as the oj, multi-json, chronic and chronic-duration Ruby gems. If you like what this bot does, donations for its upkeep and development are welcome at <https://PayPal.Me/FiXatoNL> :joy:\nThe source code is available at: #{REPOSITORY_URL}"
end

bot.message(content: '!source') do |bot_event|
  bot_event.respond "The source code is available at: #{REPOSITORY_URL}"
end

bot.include! JoinAnnouncer
bot.run

