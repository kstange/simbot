#!/usr/bin/perl

# SimBot
#
# Copyright (C) 2002-05, Kevin M Stange <kevin@simguy.net>
#
# This program is free software; you can redistribute and/or modify it
# under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# NOTE: You should not edit this file other than the path to perl at the top
#       unless you know what you are doing.  Submit bugfixes back to:
#       http://sf.net/projects/simbot

# Hi, my name(space) is:
package SimBot;

BEGIN {
	push (@INC, "./lib");
}

use SimBot::Util;

use Data::Dumper;

# Sometimes we end up in Unicode.  Since IRC and Unicode are not good
# friends, we'll take a ride back to ISO-8859-1 before we send the
# server any questionable strings.  This requires Perl 5.8.0 or a perl
# with the equivalent Encode module.
use Encode;
use constant TARGET_ENCODING => 'iso-8859-1';

# We hold our code up to some standards.
# For some well-meaning reason, strict does not allow the use of strings
# for literal references to functions and objects so we'll just tell Perl
# to let us do that without complaining.
use warnings;
use strict;
no strict 'refs';

# ****************************************
# *********** Random Variables ***********
# ****************************************

# Variables we want to use without an explicit package name
use vars qw( %chat_words $chosen_nick $chosen_server $alarm_sched_60
			 %plugin_help %plugin_params %hostmask_cache @servers
			 );

# ****************************************
# ************ Start of Script ***********
# ****************************************

&debug(DEBUG_NONE, PROJECT . " " . VERSION . "\n\n");

# Read command line options
my %args = &get_args();

# Help output
if (defined $args{help}) {
	print "Usage: simbot.pl [options]\n\n"
		. "  --config=\"filename\"\tLoads filename.ini as the config file\n"
		. "  --debug=#\t\tOverrides the default debug level.\n"
		. "\t\t\t  0 is silent, 1 shows errors, 2 shows alerts\n"
		. "\t\t\t  3 shows IRC output, 4 shows debug output,\n"
		. "\t\t\t  5 shows excessive debug output,\n"
		. "\n";
	exit(0);
}

# Load the configuration file.
&load_config(defined $args{config} ? $args{config} : "./config.ini");

# Check some config options or bail out!
die("Your configuration is lacking an IRC server to connect to")
	unless option_list('network', 'server');
die("Your configuration is lacking a channel to join")
	unless option('network', 'channel');
die("Your configuration is lacking a valid default nickname")
	unless option('global', 'nickname');
die("Your configuration has an extra sentence % >= 100%")
	unless option('chat', 'new_sentence_chance') < 100;
die("Your configuration has no rulefile to load")
	unless option('global', 'rules');

# These are intializations of the hash tables we'll be using for
# callbacks and plugin information.

### Plugin Events ###
# Plugin events get params:
#  (kernel)
our %event_plugin_load         = ();
our %event_plugin_reload       = ();
our %event_plugin_unload       = ();
# Call event gets params:
#  (kernel, from, channel, command string)
our %event_plugin_call         = ();

# Bot addressing gets params:
#  (kernel, from, channel, text string)
our %event_bot_addressed       = ();

### Channel Events ###
# Channel events get params:
#  (kernel, from, channel, eventname, params)
our %event_channel_message     = (); # eventname = SAY (text)
our %event_channel_message_out = (); # eventname = SAY (text)
our %event_channel_action      = (); # eventname = ACTION (text)
our %event_channel_action_out  = (); # eventname = ACTION (text)
our %event_channel_notice      = (); # eventname = NOTICE (text)
our %event_channel_notice_out  = (); # eventname = NOTICE (text)
our %event_channel_kick        = (); # eventname = KICKED (text, kicker)
our %event_channel_mode        = (); # eventname = MODE (modes, arguments...)
our %event_channel_topic       = (); # eventname = TOPIC (text)
our %event_channel_join        = (); # eventname = JOINED ()
our %event_channel_part        = (); # eventname = PARTED (message)
our %event_channel_quit        = (); # eventname = QUIT (message)
our %event_channel_mejoin      = (); # eventname = JOINED ()
our %event_channel_nojoin      = (); # eventname = NOTJOINED (message)
our %event_channel_novoice     = (); # eventname = CANTSAY ()
our %event_channel_invite      = (); # eventname = INVITED ()

### Private Events ###
# Private events get params:
#  (kernel, from, eventname, text)
our %event_private_message     = (); # eventname = PRIVMSG ()
our %event_private_action      = (); # eventname = PRIVACTION ()
our %event_private_notice      = (); # eventname = NOTICE ()

#  (kernel, from, dest, eventname, text)
our %event_private_message_out = (); # eventname = PRIVMSG ()
our %event_private_action_out  = (); # eventname = PRIVACTION ()
our %event_private_notice_out  = (); # eventname = NOTICE ()

### Server Events ###
# Server events get params:
#  (kernel, server, nickname, params)
our %event_server_connect      = (); # ()
our %event_server_ison         = (); # (nicks list...)
our %event_server_nick         = (); # (new nickname)

### Function Queries ###
# Function queries get params:
#  (kernel, params)
our %query_word_score          = (); # (text, start score)
our %query_userhost_mask       = (); # (user@host)


our @list_nicks_ison           = (
								  option('global', 'nickname'),
								  );

### Stock IRC Operations ###
# Your services plugin will probably want to override these, however
# if you do, it might not be a terrible idea to grab the original
# reference and call that if you still want to use the standard IRC
# functionality in your routine.
our %commands = (
				 # kick (kernel, channel, user, message)
				 kick =>    \&irc_ops_kick,
				 # ban (kernel, channel, user, time (secs), message)
				 ban =>     \&irc_ops_ban,
				 # unban (kernel, channel, user)
				 unban =>   \&irc_ops_unban,
				 # op (kernel, channel, user)
				 op =>      \&irc_ops_op,
				 # deop (kernel, channel, user)
				 deop =>    \&irc_ops_deop,
				 # voice (kernel, channel, user)
				 voice =>   \&irc_ops_voice,
				 # devoice (kernel, channel, user)
				 devoice => \&irc_ops_devoice,
				 # topic (kernel, channel, new topic)
				 topic =>   \&irc_ops_topic,
				 );

# This provides the descriptions of plugins.  If a plugin has no
# defined description, it is "hidden" and will not appear in help.
&debug(DEBUG_SPAM, "Registering internal plugins... \n");

# register the snooze plugin only if snooze is allowed
if(option('chat','snooze') !~ m/always|never/) {
    &plugin_register(plugin_id   => "snooze",
					 plugin_params => "<on|off>",
					 plugin_help => "Toggles snooze mode which prevents " .
					 "recording and responding to chat. Commands are still " .
					 "processed.",
					 event_plugin_call     => \&set_snooze,
					 );
}

&plugin_register(plugin_id   => "stats",
				 plugin_help => "Shows various statistics about the database.",
				 event_plugin_call     => \&print_stats,
				 );

&plugin_register(plugin_id   => "help",
				 plugin_params => "<command name>",
				 plugin_help => "Displays a list of available commands. Adding a command name as a parameter will display help text for that command.",
				 event_plugin_call     => \&print_help,
				 );


# Register the delete plugin only if the option is enabled
if(option('chat', 'delete_usage_max') != -1) {
	&plugin_register(plugin_id   => "delete",
					 plugin_params => "<word>",
					 plugin_help => "Erases a word that has been previously learned.",
					 event_plugin_call     => \&delete_words,
					 );
}

# Now that we've initialized the callback tables, let's load
# all the plugins that we can from the plugins directory.
opendir(DIR, "./plugins");
foreach my $plugin (readdir(DIR)) {
    if($plugin =~ /.*\.pl$/) {
		if($plugin =~ /^services\.(.+)\.pl$/) {
			&debug(DEBUG_SPAM, "$1 services plugin found.\n");
			if (option('services','type') eq $1) {
				&debug(DEBUG_SPAM, "$1 services plugin was selected. Attempting to load...\n");
				if (eval { require "./plugins/$plugin"; }) {
					&debug(DEBUG_STD, "$1 services plugin loaded successfully.\n");
				} else {
					&debug(DEBUG_ERR, "$@");
					&debug(DEBUG_WARN, "$1 service plugin did not load due to errors.\n");
				}
			} else {
				&debug(DEBUG_SPAM, "$1 services plugin was not selected.\n");
			}
		} elsif(eval { require "./plugins/$plugin"; }) {
			&debug(DEBUG_STD, "$plugin plugin loaded successfully.\n");
		} else {
			&debug(DEBUG_ERR, "$@");
			&debug(DEBUG_WARN, "$plugin plugin did not load due to errors.\n");
		}
    }
}
closedir(DIR);

# Here are some globals that should be initialized because someone
# might try to look at them before they get set to something.
our $loaded      = 0; # The rules are not loaded yet.
our $items       = 0; # We haven't seen any lines yet.
our $terminating = 0; # We are not terminating in the default case.

# set the snooze variable to the proper default
our $snooze = (option('chat','snooze') =~ m/on|always/) ? 1 : 0;

# Load the massive table of rules simbot will need.
&load;

# Now that everything is loaded, let's prepare to connect to IRC.
# We'll need this perl module to be able to do anything meaningful.
our $kernel = new POE::Kernel;
use POE;
use POE::Component::IRC;

# Create a new IRC connection.
POE::Component::IRC->spawn(alias => 'bot');

# Add the handlers for different IRC events we want to know about.
POE::Session->create(
	inline_states => {
		_start           => \&initialize,
		irc_001          => \&irc_connected,    # connected
		irc_005          => \&server_supports,  # RPL_ISUPPORT
		irc_433          => \&pick_new_nick,    # nickname in use
		irc_socketerr    => \&socket_error,     # internet wants to yell at us
		irc_error        => \&server_error,     # server wants to yell at us
		irc_465          => \&server_banned,    # ERR_YOUREBANNEDCREEP
		irc_disconnected => \&irc_disconnected, # disconnected
		irc_303          => \&server_ison,      # check ison reply
		irc_352          => \&server_who,       # check who reply
		irc_nick         => \&server_nick_change,
		irc_401          => \&server_no_such_nick, # No such nick/chan error
		irc_msg          => \&private_message,
		irc_public       => \&channel_message,
		irc_kick         => \&channel_kick,
		irc_join         => \&channel_join,
		irc_part         => \&channel_part,
		irc_quit         => \&channel_quit,
		irc_404          => \&channel_novoice, # we can't speak for some reason
		irc_471          => \&channel_nojoin,  # channel is at limit
		irc_473          => \&channel_nojoin,  # channel invite only
		irc_474          => \&channel_nojoin,  # banned from channel
		irc_475          => \&channel_nojoin,  # bad channel key
		irc_invite       => \&channel_invite,
		irc_topic        => \&channel_topic,
		irc_mode         => \&channel_mode,
		irc_notice       => \&process_notice,
		irc_ctcp_action  => \&process_action,
		irc_ctcp_version => \&process_version,
		irc_ctcp_time    => \&process_time,
		irc_ctcp_finger  => \&process_finger,
		irc_ctcp_ping    => \&process_ping,
		irc_snotice      => \&server_notice,

		# Custom Events
		scheduler_60     => \&run_scheduler_60, # run events every 60 seconds
		cont_send_pieces => \&cont_send_pieces, # send the rest of the pieces
		quit_session     => \&quit_session,     # end the session and terminate
		restart          => \&restart,          # end the session and restart
		rehash           => \&rehash,           # reload data files
	},
					 );

# ****************************************
# ********* Start of Subroutines *********
# ****************************************

# ########### GENERAL PURPOSE ############

# HOSTMASK: Generates a 'type 3' hostmask from a nick!user@host address
sub hostmask {
    my ($nick, $user, $host) = split(/[@!]/, $_[0]);
	if (!defined $user && !defined $host) {
		if (defined &get_hostmask($nick)) {
			(undef, $user, $host) = split(/[@!]/, &get_hostmask($nick));
		} else {
			$user = "*";
			$host = "*";
		}
	}

	my $changed = 0;
	foreach my $plugin (keys(%query_userhost_mask)) {
		my $newmask = &plugin_callback($plugin, $query_userhost_mask{$plugin}, ("$user\@$host"));
		if (defined $newmask && $newmask =~ /.@./) {
			&debug(DEBUG_SPAM, "hostmask: the $plugin plugin changed the user\@host mask\n");
			($user, $host) = split(/@/, $newmask);
			$changed = 1;
			last;
		}
	}

	$nick = "*" unless ($host =~ /\*/ && $user eq "*");
	$user =~ s/^~?/*/ unless $user eq "*";

	if (!$changed) {
		if ($host =~ /^(\d{1,3}\.){3}\d{1,3}$/) {
			$host =~ s/(\.\d{1,3}){2}$/\.\*/;
		} elsif ($host =~ /(([A-F0-9]{0,4}:){3})[A-F0-9]{0,4}$/i) {
			$host =~ "$1:*";
		} elsif ($host =~ /^(.*)(\.\w*?\.[\w\.]{3,6})$/) {
			$host = "*$2";
		}
	}

	&debug(DEBUG_SPAM, "hostmask: returning type 3 hostmask: $nick!$user\@$host\n");
    return "$nick!$user\@$host";
}

# SET_HOSTMASK: Caches a new hostmask for a nickname
sub set_hostmask {
	my ($nick, $mask) = @_;
	if (defined $mask) {
		$hostmask_cache{lc($nick)} = $mask;
	} else {
		delete $hostmask_cache{lc($nick)};
	}
}

# GET_HOSTMASK: Returns the hostmask for a nickname
sub get_hostmask {
	my $nick = lc($_[0]);
	return (defined $hostmask_cache{$nick} ? $hostmask_cache{$nick} : undef);
}

# ############ IRC OPERATIONS ############

# These are the functions that a plugin should call to run an IRC operation.
# The kernel does not need to be passed to these functions
sub send_kick    { &{$commands{kick}}   ($kernel, @_); }
sub send_ban     { &{$commands{ban}}    ($kernel, @_); }
sub send_unban   { &{$commands{unban}}  ($kernel, @_); }
sub send_op      { &{$commands{op}}     ($kernel, @_); }
sub send_deop    { &{$commands{deop}}   ($kernel, @_); }
sub send_voice   { &{$commands{voice}}  ($kernel, @_); }
sub send_devoice { &{$commands{devoice}}($kernel, @_); }
sub send_topic   { &{$commands{topic}}  ($kernel, @_); }

sub irc_ops_kick {
	my ($kernel, $channel, $user, $message) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to kick $user from $channel ($message)\n");
	$kernel->post(bot => kick => $channel, $user, $message);
}

sub irc_ops_ban {
	my ($kernel, $channel, $user, $time, $message) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to ban $user from $channel ($message)"
		  . ($time > 0 ? " for $time seconds" : "") . "\n");
	$kernel->post(bot => mode => $channel, "+b", hostmask($user));
	send_kick($channel, $user, $message);
	if ($time > 0) {
		$kernel->delay('irc_ops_unban', $time, $channel, hostmask($user));
	}
}

sub irc_ops_unban {
	my ($kernel, $channel, $user) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to unban $user from $channel\n");
	$kernel->post(bot => mode => $channel, "-b", hostmask($user));
}

sub irc_ops_op {
	my ($kernel, $channel, $user) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to op $user on $channel\n");
	$kernel->post(bot => mode => $channel, "+o", $user);
}

sub irc_ops_deop {
	my ($kernel, $channel, $user) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to deop $user on $channel\n");
	$kernel->post(bot => mode => $channel, "-o", $user);
}

sub irc_ops_voice {
	my ($kernel, $channel, $user) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to voice $user on $channel\n");
	$kernel->post(bot => mode => $channel, "+v", $user);
}

sub irc_ops_devoice {
	my ($kernel, $channel, $user) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to devoice $user on $channel\n");
	$kernel->post(bot => mode => $channel, "-v", $user);
}

sub irc_ops_topic {
	my ($kernel, $channel, $topic) = @_;
	&debug(DEBUG_INFO, "Irc Ops: attempting to set the topic to $topic on $channel\n");
	$kernel->post(bot => topic => $channel, $topic);
}

# ########### FILE OPERATIONS ############

# LOAD: This will load our rules.
sub load {
	my $rulefile = option('global', 'rules');
	my ($lfound, $rfound);
	my $deleted = 0;
    &debug(DEBUG_STD, "Loading $rulefile... ");
    $loaded = 0;
    if(open(RULES, $rulefile)) {
		foreach(<RULES>) {
			chomp;
			s/\r//;
			my @rule = split (/\t/);
			$chat_words{$rule[0]}{$rule[1]}[1] = $rule[2];
			$chat_words{$rule[1]}{$rule[0]}[0] = $rule[2];
		}
		close(RULES);
		&debug(DEBUG_STD, "Rules loaded successfully!\n", DEBUG_NO_PREFIX);
		$loaded = 1;

		&debug(DEBUG_STD, "Checking for lost words... ");
		foreach my $word (keys(%chat_words)) {
			next if ($word =~ /^__[\!\?]?[A-Z]*$/);
			$lfound = 0;
			$rfound = 0;
			foreach (keys(%{$chat_words{$word}})) {
				# If we find out a word has any links to the right, we're good.
				if (defined $chat_words{$word}{$_}[1] && $rfound == 0) {
					$rfound = 1;
				}
				# If we find out a word has any links to the left, we're good.
				if (defined $chat_words{$word}{$_}[0] && $lfound == 0) {
					$lfound = 1;
				}
			}
			if ($lfound == 0 || $rfound == 0) {
				print "\n" if !$deleted;
				$deleted = 1;
				delete_word($word, 0);
			}
		}
		if (!$deleted) {
			&debug(DEBUG_STD, "No lost words found!\n");
		} else {
			&debug(DEBUG_STD, "All lost words removed successfully.\n");
		}

    } elsif (!-e $rulefile) {
		&debug(DEBUG_WARN, "File does not exist and will be created on save.\n");
		$loaded = 1;
    } else {
		&debug(DEBUG_ERR, "Cannot read from the rules file! This session will not be saved!\n");
    }
}

# SAVE: This will save our rules.
sub save {
	my $rulefile = option('global', 'rules');
    &debug(DEBUG_STD, "Saving $rulefile... ");
    if ($loaded == 1) {
		if(open(RULES, ">$rulefile")) {
			flock(RULES, 2);
			foreach(keys(%chat_words)) {
				my $a = $_;
				foreach(keys(%{$chat_words{$a}})) {
					my $b = $_;
					my $c = $chat_words{$a}{$b}[1];
					print RULES "$a\t$b\t$c\n" if defined $c;
				}
			}
			flock(RULES, 8);
			close(RULES);
			&debug(DEBUG_STD, "Rules saved successfully!\n");
		} else {
			&debug(DEBUG_ERR, "Cannot write to the rules file! This session will be lost!\n");
		}
    } else {
		&debug(DEBUG_WARN, "Opting not to save.  Rules are not loaded.\n");
    }
    $items = 0;
}

# ########### PLUGIN OPERATIONS ############

# PLUGIN_REGISTER: Registers a plugin (or doesn't).
sub plugin_register {
    my %data = @_;
	$data{plugin_id} = lc($data{plugin_id});
    if(!$event_plugin_call{$data{plugin_id}}) {
		&debug(DEBUG_SPAM, $data{plugin_id} . ": no plugin conflicts detected\n");
    } else {
		die("$data{plugin_id}: a plugin is already registered to this handle");
    }
    if ($data{event_plugin_load}) {
		if (!&plugin_callback($data{plugin_id}, $data{event_plugin_load})) {
			die("$data{plugin_id}: the plugin returned an error on load");
		}

    }
    $event_plugin_call{$data{plugin_id}} = $data{event_plugin_call};
    if(!$data{plugin_help}) {
		&debug(DEBUG_SPAM, $data{plugin_id} . ": this plugin has no help text and will be hidden\n");
    } else {
		$plugin_help{$data{plugin_id}} = $data{plugin_help};
    }
	$plugin_params{$data{plugin_id}} = $data{plugin_params};
    foreach (keys(%data)) {
		if ($_ =~ /^event_(plugin|bot|channel|private|server)_.*/) {
			$$_{$data{plugin_id}} = $data{$_};
		} elsif ($_ =~ /^query_.*/) {
			$$_{$data{plugin_id}} = $data{$_};
        } elsif ($_ =~ /^list_.*/) {
			my @list = split(/,\s*/, $data{$_});
			push(@{$_}, @list);
        } elsif ($_ =~ /^hash_.*/) {
			$$_{$data{plugin_id}} = $data{$_};
        }
    }
    return 1;
}

# PLUGIN_CALLBACK: Calls the given plugin function with paramters.
sub plugin_callback {
    my ($plugin, $function, @params) = @_;
	&debug(DEBUG_SPAM, "Running callback to $function in $plugin.\n");
	return &$function($kernel, @params);
}

# SET_SNOOZE: Sets the snooze mode on or off.
sub set_snooze {
    my ($nick, $channel, $option) = @_[1,2,4];
	if (lc($option) eq "off") {
		if ($snooze) {
			$snooze = 0;
			&debug(DEBUG_STD, "snooze: Snooze mode was turned OFF by $nick.\n");
			&send_action($channel, "streches and yawns.");
			&send_message($channel, "$nick: Thanks for the wake up call.  Time to get back to work!");
		} else {
			&debug(DEBUG_INFO, "snooze: Snooze mode was OFF, but $nick wanted to try anyway.\n");
			&send_message($channel, "$nick: Do I look like I'm sleeping to you?");
		}
	} elsif (lc($option) eq "on") {
		if ($snooze) {
			&debug(DEBUG_INFO, "snooze: Snooze mode was ON, but $nick wanted to try anyway.\n");
			&send_message($channel, "$nick: You're waking me up to tell me to take a nap?  What kind of monster are you!?");
		} else {
			$snooze = 1;
			&debug(DEBUG_STD, "snooze: Snooze mode was turned ON by $nick.\n");
			&send_message($channel, "$nick: You know, a nap sounds great right about now.  Wake me if you need anything.");
			&send_action($channel, "lays down and begins to snore....");
		}
	} else {
		&send_message($channel, "$nick: Snooze mode is " . ($snooze ? "ON" : "OFF") . ".  Specify 'on' to enter snooze mode.  I will stop paying attention to chat, but I'll still look for commands.  Specify 'off' to wake me back up.");

	}
}

# PRINT_HELP: Prints a list of valid commands privately to the user.
sub print_help {
    my ($nick, $command) = @_[1,4];
	my $prefix = option('global', 'command_prefix');
	my $message;
    &debug(DEBUG_INFO, "help: requested by " . $nick . "." .
		   (defined $command ? " ($command)" : "") . "\n");
	if (!defined $command) {
		$message = "Prefix commands with '$prefix' when you use them. For help with a command, try typing %bold%" . $prefix . "help <command>%bold%\n";
		my $count = 0;
		my @commands = sort {$a cmp $b} keys(%plugin_help);
		while (defined $commands[$count]) {
			$message .= sprintf(" %-12s  %-12s  %-12s %-12s\n",
								$commands[$count++], $commands[$count++],
								$commands[$count++], $commands[$count++]);
		}
	} else {
		$command =~ s/^$prefix//;
		if (!defined $plugin_help{$command} &&
			!defined $plugin_params{$command}) {
			$message = "There is no help for that command, or it does not exist.";
		} else {
			$message = "%uline%Usage:%uline% %bold%${prefix}$command%bold% "
				. (defined $plugin_params{$command}
				   ? $plugin_params{$command} : "")
				. (defined $plugin_help{$command}
				   ? "\n$plugin_help{$command}" : "");
		}
	}
	$message = parse_style($message);
	chomp $message;
	&send_pieces($nick, undef, $message);
}

# PRINT_STATS: Prints some useless stats about the bot to the channel.
sub print_stats {
    my $nick = $_[1];
    my $channel = $_[2];
    my (@ldeadwords, @rdeadwords) = ();
    my ($message, $wordpop);
    my ($lfound, $lcount, $rfound, $rcount, $wordpopcount) = (0, 0, 0, 0, 0);

    &debug(DEBUG_INFO, "stats: requested by " . $nick . ".\n");
    my $count = keys(%chat_words);
    my $begins = keys(%{$chat_words{'__BEGIN'}}) + keys(%{$chat_words{'__!BEGIN'}}) + keys(%{$chat_words{'__?BEGIN'}});
    my $ends = keys(%{$chat_words{'__END'}}) + keys(%{$chat_words{'__!END'}}) + keys(%{$chat_words{'__?END'}});
    my $actions = keys(%{$chat_words{'__ACTION'}});
    &send_message($channel, "In total, I know $count words.  I've learned $begins words that I can start a sentence with, and $ends words that I can end one with.  I know of $actions ways to start an IRC action (/me).");

    # Process through the list and find words that have no links in one or
    # both directions (because we can never use these words safely).  We'll
    # be nice and efficient and use this same loop to find the most frequent
    # two word sequence.
    foreach my $word (keys(%chat_words)) {
		next if ($word =~ /^__[\!\?]?[A-Z]*$/);
		$lfound = 0;
		$rfound = 0;
		foreach (keys(%{$chat_words{$word}})) {
			# If we find out a word has any links to the right, we're good.
			if (defined $chat_words{$word}{$_}[1] && $rfound == 0) {
				$rfound = 1;
			}
			# If we find out a word has any links to the left, we're good.
			if (defined $chat_words{$word}{$_}[0] && $lfound == 0) {
				$lfound = 1;
			}
			# Find the most popular two word sequence.
			if (defined $chat_words{$word}{$_}[1]) {
				if ($chat_words{$word}{$_}[1] > $wordpopcount
					&& $_ !~ /^__[\!\?]?[A-Z]*$/
					&& length($word) > 3 && length($_) > 3) {
					$wordpop = "$word $_";
					$wordpopcount = $chat_words{$word}{$_}[1];
				}
			}
		}
		if ($lfound == 0) {
			$lcount++;
			push(@ldeadwords, "'$word'");
		}
		if ($rfound == 0) {
			$rcount++;
			push(@rdeadwords, "'$word'");
		}
    }
	&send_message($channel, "The most popular two word sequence (with more than 3 letters) is \"$wordpop\" which has been used $wordpopcount times.");
    if ($rcount > 0) {
		&send_pieces($channel, "", "There are $rcount words that lead me to unexpected dead ends. They are: @rdeadwords");
    }
    if ($lcount > 0) {
		&send_pieces($channel, "", "There are $lcount words that lead me to unexpected dead beginnings.  They are: @ldeadwords");
    }
}

# DELETE_WORDS: This removes a word, if it hasn't been deeply ingrained
# in the database (used a lot) and tells the user what has been done.
sub delete_words {
    my (undef, $nick, $channel, undef, $word) = @_;
	my $max = option('chat', 'delete_usage_max');
	$word = lc($word);
	if (defined $word && $word ne "") {
		my @deleted = &delete_word($word, $max);
		if (!@deleted && !defined $chat_words{$word}) {
			&send_message($channel, "$nick: I don't remember ever seeing that word before. It will be hard to forget it.");
		} elsif (!@deleted) {
			&send_message($channel, "$nick: '$word' may not be deleted because I've seen it used more than $max times.");
		} else {
			&send_message($channel, "$nick: I've supressed any knowledge of the words: " . join(", ", @deleted));
		}
	} else {
		&send_message($channel, "$nick: You need to tell me which word you want me to dropkick to oblivion.");
	}
}

# ######### CONVERSATION LOGIC ###########

# BUILD_RECORDS: This creates new rules and adds them to the database.
sub build_records {
    my $action = ($_[1] ? $_[1] : "");
    my @sentence = split(/\s+/, $_[0]);
    $items++;

    my $tail = -1;
	my $punc = "";

	# Eat anything that looks like it might be a smiley at end of our line.
	if (defined $sentence[$tail]) {
		while ($sentence[$tail] =~ /^[:;=].*/) {
			$tail--;
		}
		# Look for punctuation to be recorded.
		$sentence[$tail] =~ /([\!\?])[^\!\?]*$/;
		$punc = $1 if(defined $1);
	}

	# Define the start and end tags such that we reflect the punctuation
	# we found.
    my $startblock = "__" . $punc . "BEGIN";
    my $endblock = "__END";

	# Go through every word and sanitize the text so that we record as little
	# junk as possible.
	for(my $x=0; $x <= $#sentence; $x++) {
		# Eat smileys. The second line tries to eat smileys with ='s for eyes.
		$sentence[$x] =~ s/^[;:].*//;
		$sentence[$x] =~ s/^=[^=]+//;

		if($sentence[$x] =~ m/.>$/) {
			while($x+1 > 0) {
				shift(@sentence);
				$x--;
			}
		}

		goto skiptosave if(!@sentence); # Yipes, a goto!

		# Remove all characters that we don't like.  Right now we accept
		# letters, numbers, international characters (ASCII), as well as:
		# ', /, -, ., =, %, $, &, +, @
		$sentence[$x] =~ s/[^\300-\377\w\'\/\-\.=\%\$&\+\@]*//g;
		# Don't record dots that aren't inside a word.
		$sentence[$x] =~ s#(^|\s)\.+|\.+(\s|$)##g;
		# For the safety of everyone, we record in lowercase.
		$sentence[$x] = lc($sentence[$x]);

		# After all this, if we're short on letters, we can't record this.
		if ("@sentence" !~ /[A-Za-z0-9\300-\377]/) {
			&debug(DEBUG_INFO, "This line contained no discernable words: @sentence\n");
			goto skiptosave; # Oh my, a goto!
		}

		# If we match any of the filters defined by the user's config file,
		# we're not going to record this line.
		foreach (option_list('filters')) {
			if ($sentence[$x] =~ /$_/) {
				&debug(DEBUG_INFO, "Not recording this line: @sentence\n");
				goto skiptosave; # Oh my, a goto!
			}
		}
    }

	# Lines of nothing but whitespace aren't worth trying to record.
    if ("@sentence" =~ /^\s*$/) {
		&debug(DEBUG_INFO, "This line contained no discernable words: @sentence\n");
		goto skiptosave; # Oh my, a goto!
    }

	# If this was an IRC action, we want to remember this in the database.
    if ($action eq "ACTION") {
		@sentence = ("__ACTION", @sentence);
    }

	# Assemble the sentence!
    @sentence = ($startblock, @sentence, $endblock);

    my $i = 0;
    while ($i < $#sentence) {
		if($sentence[$i+1] ne "") {
			my $cur_word = $sentence[$i];
			my $y = 0;
			# Skip over any empty words in the array.
			while ($cur_word eq "") {
				$y++;
				$cur_word = $sentence[$i-$y];
			}
			# If we've seen this word pairing before, simply increment the
			# counter.
			if ($chat_words{$cur_word}{$sentence[$i+1]}[1]) {
				$chat_words{$cur_word}{$sentence[$i+1]}[1]++;
				$chat_words{$sentence[$i+1]}{$cur_word}[0]++;
				&debug(DEBUG_INFO, "Updating $cur_word-\>$sentence[$i+1] to " . $chat_words{$cur_word}{$sentence[$i+1]}[1] . "\n");
				&debug(DEBUG_SPAM, "Updating $sentence[$i+1]-\>$cur_word to " . $chat_words{$sentence[$i+1]}{$cur_word}[0] . " (reverse)\n");

			# Otherwise, add the word pairing as new to the database.
			} else {
				$chat_words{$cur_word}{$sentence[$i+1]}[1] = 1;
				$chat_words{$sentence[$i+1]}{$cur_word}[0] = 1;
				&debug(DEBUG_INFO, "Adding $cur_word-\>$sentence[$i+1]\n");
				&debug(DEBUG_SPAM, "Adding $sentence[$i+1]-\>$cur_word (reverse)\n");
			}
		}
		$i++;
    }

  skiptosave: # Oh my, a goto label!
	# Check to see if it's time to save the data.  Right now we do this
	# every time we record 20 new items to the database.
    if ($items >= 20) {
		&save;
    }
}

# BUILD_REPLY: This creates a random reply from the database.
sub build_reply {
	# No reason to waste effort if the database is empty.
    if (%chat_words) {
		my @sentence = split(/ /, $_[0]);

		# find an interesting word to base the sentence off
		my $newword = &find_interesting_word(@sentence);

		my $middleword = $newword;
		my $return = ($newword ? "$newword " : "");
		my $punc = "";
		while ($newword !~ /^__[\!\?]?END$/) {
			my $chcount = 0;
			if (!$newword) {
				my %choices = ("__BEGIN", 0,
							   "__!BEGIN", 0,
							   "__?BEGIN", 0,
							   );
				foreach my $key (keys(%choices)) {
					foreach (keys(%{$chat_words{$key}})) {
						$choices{$key} = 0 if !$choices{$key};
						$choices{$key} += $chat_words{$key}{$_}[1];
					}
					$chcount += $choices{$key};
				}
				my $try = int(rand()*($chcount))+1;
				foreach(keys(%choices)) {
					$try -= $choices{$_};
					if ($try <= 0) {
						$newword = $_;
						m/^__([\!\?])?BEGIN$/;
						if ($1) {
							$punc = $1;
							debug(DEBUG_INFO, "Using '$1' from __BEGIN\n");
						}
						last;
					}
				}
			}
			$chcount = 0;
			if ($newword) {
				foreach (keys(%{$chat_words{$newword}})) {
					$chcount += $chat_words{$newword}{$_}[1] if defined $chat_words{$newword}{$_}[1];
				}
				debug(DEBUG_SPAM, "$chcount choices for next to $newword\n");
			}
			my $try = int(rand()*($chcount))+1;
			foreach(keys(%{$chat_words{$newword}})) {
				$try -= $chat_words{$newword}{$_}[1] if defined $chat_words{$newword}{$_}[1];
				if ($try <= 0) {
					debug(DEBUG_SPAM, "Selected $_ to follow $newword\n");
					$newword = $_;
					if($newword =~ /^__([\!\?])?END$/) {
						if ($1 && !$punc) {
							$punc = $1;
							debug(DEBUG_INFO, "Using '$1' from __END\n");
						}
					} else {
						$return .= $newword . " ";
					}
					last;
				}
			}
			if ($try > 0) {
				$newword = "__END";
				&debug(DEBUG_ERR, "Database problem!  Hit a dead end in \"$return\"...\n");
			}
		} # ENDS while

		# If we had an interesting "middleword", this segment of code will
		# generate the first part of the sentence and tack it on before the
		# end that we've already generated.
		if($middleword) {
			$newword = $middleword;
			while ($newword !~ /^__[\!\?]?BEGIN$/) {
				my $chcount = 0;
				foreach (keys(%{$chat_words{$newword}})) {
					$chcount += $chat_words{$newword}{$_}[0] if defined $chat_words{$newword}{$_}[0];
				}
				&debug(DEBUG_SPAM, "$chcount choices for next to $newword\n");
				my $try = int(rand()*($chcount))+1;
				foreach(keys(%{$chat_words{$newword}})) {
					$try -= $chat_words{$newword}{$_}[0] if defined $chat_words{$newword}{$_}[0];
					if ($try <= 0) {
						debug(DEBUG_SPAM, "Selected $_ to follow $newword\n");
						$newword = $_;
						if($newword =~ /^__([\!\?])?BEGIN$/) {
							if ($1) {
								$punc = $1;
								debug(DEBUG_INFO, "Using '$1' from __BEGIN\n");
							}
						} else {
							$return = $newword . " " . $return;
						}
						last;
					}
				}
				if ($try > 0) {
					$newword = "__BEGIN";
					&debug(DEBUG_ERR, "Database problem!  Hit a dead beginning in \"$return\"...\n");
				}
			} # ENDS while
		}
		$return =~ s/\s+$//;
		$return = uc(substr($return, 0,1)) . substr($return, 1) . ($punc ne "" ? $punc : ".");
		$return =~ s/\bi(\b|\')/I$1/g; # '
		my $chance = option('chat', 'new_sentence_chance');
		if ($chance && int(rand()*(100/$chance)) == 0) {
			&debug(DEBUG_INFO, "Adding another sentence...\n");
			$return .= "__NEW__" . &build_reply("");
		}
		return $return;
    } else {
		&debug(DEBUG_ERR, "Could not form a reply.\n");
		return "I'm speechless.";
    }
}

# FIND_INTERESTING_WORD: Finds a word to base a sentence off
sub find_interesting_word {
	my ($curWordScore, $highestScoreWord, $highestScore, $curWord);
	my $nickmatch = "^(" . $chosen_nick . "|" .
		option('global', 'nickname') . "|" .
		option('global', 'alt_tag') . ")\$";

	# The point here is to pick a base score that adapts a bit to the size of
	# the database
	my $startScore = int((keys(%chat_words) ** 0.1) * 5000);

	debug(DEBUG_INFO, "Word scores: ");
    $highestScoreWord = ""; $highestScore=0;
	foreach my $curWord (@_) {
        $curWord = lc($curWord);
        $curWord =~ s/[,\.\?\!\:]*$//;
        if(!defined $chat_words{$curWord}
           || $curWord =~ /$nickmatch/i) {
            next;
        }
		$curWordScore = $startScore;
		foreach(keys(%query_word_score)) {
			$curWordScore += &plugin_callback($_, $query_word_score{$_}, ($curWord), $startScore);
		}

		foreach my $nextWord (keys(%{$chat_words{$curWord}})) {
			if($nextWord =~ /__[\.\?\!]?(END|BEGIN)$/) {
				$curWordScore -= 1.8 * $chat_words{$curWord}{$nextWord}[1] if defined $chat_words{$curWord}{$nextWord}[1];
				$curWordScore -= 1.8 * $chat_words{$curWord}{$nextWord}[0] if defined $chat_words{$curWord}{$nextWord}[0];
			} else {
				$curWordScore -= $chat_words{$curWord}{$nextWord}[1] if defined $chat_words{$curWord}{$nextWord}[1];
            }
        }
        $curWordScore += .7 * length($curWord);
        &debug(DEBUG_INFO, "$curWord:$curWordScore ", DEBUG_NO_PREFIX);
        if($curWordScore > $highestScore) {
            $highestScore = $curWordScore;
            $highestScoreWord = $curWord;
        }
    }
	&debug(DEBUG_INFO, "\n", DEBUG_NO_PREFIX);
    &debug(DEBUG_INFO, "Using $highestScoreWord\n");
    return $highestScoreWord;
}

# DELETE_WORD: Removes a word and any exclusive chains from that word
# from the database.  The second argument is a number, which prevents
# removal of a word used more than a certain number of times.  To force
# word removal, use 0.
sub delete_word {
    my ($word, $count, @path_words) = @_;
	my @deleted = ();
	$word = lc($word);
	if (defined $chat_words{$word}) {
		my ($use_left, $use_right) = (0,0);
		foreach(keys(%{$chat_words{$word}})) {
			$use_left += $chat_words{$word}{$_}[0] if defined $chat_words{$word}{$_}[0];
			$use_right += $chat_words{$word}{$_}[1] if defined $chat_words{$word}{$_}[1];
		}
		&debug(DEBUG_SPAM, "delete: $word has been seen $use_left or $use_right times\n");
		if($count == 0 || ($use_left <= $count && $use_right <= $count)) {
			foreach my $next (keys(%{$chat_words{$word}})) {
				if ($next eq $word) {
					&debug(DEBUG_SPAM, "delete: skipped a loop from $word to $next\n");
					next;
				}

				my $loop = 0;
				foreach(@path_words) {
					if($next eq $_) {
						&debug(DEBUG_SPAM, "delete: skipped a loop from $word to $next\n");
						$loop = 1;
						last;
					}
				}
				next if $loop == 1;

				if (defined $chat_words{$next}{$word}
					&& keys(%{$chat_words{$next}}) <= 2) {
					push(@deleted, &delete_word($next, 0, (@path_words, $word)));
				} else {
					&debug(DEBUG_SPAM, "delete: a reference from $word to $next was deleted from the database\n");
					delete($chat_words{$next}{$word});
				}
			}
			&debug(DEBUG_STD, "delete: $word was deleted from the database\n");
			delete($chat_words{$word});
			push(@deleted, $word);
			return (@deleted);
		} else {
			&debug(DEBUG_STD, "delete: $word was NOT deleted from the database\n");
			return (@deleted);
		}
	} else {
		&debug(DEBUG_SPAM, "delete: $word ... no such word is known\n");
		return (@deleted);
	}
}

# SEND_MESSAGE: This sends a message and provides something we can hook
# into for logging what the bot says for plugins and whatnot.
sub send_message {
	my ($dest, $text) = @_;

	$text = &char_sub($text);
	$text = &Encode::encode(TARGET_ENCODING, $text);
	$kernel->post(bot => privmsg => $dest, $text);
    my $public = 0;
	if(@{$dest}) {
		foreach(@{$dest}) {
			if($_ =~ /[\#\&].+/) {
				$public = 1;
			}
		}
	} elsif($dest =~ /[\#\&].+/) {
		$public = 1;
	}
	&debug((3 + (!$public)), "[" . (@{$dest} ? "@{$dest}" : $dest) .
		   ":$chosen_nick] $text\n");

    if($public) {
		foreach(keys(%event_channel_message_out)) {
			&plugin_callback($_, $event_channel_message_out{$_}, ($chosen_nick, $dest, 'SAY', $text));
		}
	} else {
		foreach(keys(%event_private_message_out)) {
			&plugin_callback($_, $event_private_message_out{$_}, ($chosen_nick, $dest, 'PRIVMSG', $text));
		}
	}
}

# SEND_ACTION: This sends an action and provides something we can hook
# into for logging what the bot says for plugins and whatnot.
sub send_action {
	my ($dest, $text) = @_;
	$text = &char_sub($text);
	$text = &Encode::encode(TARGET_ENCODING, $text);
	$kernel->post(bot => ctcp => $dest, 'ACTION', $text);
    my $public = 0;
	if(@{$dest}) {
		foreach(@{$dest}) {
			if($_ =~ /[\#\&].+/) {
				$public = 1;
			}
		}
	} elsif($dest =~ /[\#\&].+/) {
		$public = 1;
	}
	&debug((3 + (!$public)), "[" . (@{$dest} ? "@{$dest}" : $dest) .
		   ":$chosen_nick] [action] $chosen_nick $text\n");
    if($public) {
		foreach(keys(%event_channel_action_out)) {
			&plugin_callback($_, $event_channel_action_out{$_}, ($chosen_nick, $dest, 'ACTION', $text));
		}
	} else {
		foreach(keys(%event_private_action_out)) {
			&plugin_callback($_, $event_private_action_out{$_}, ($chosen_nick, $dest, 'PRIVACTION', $text));
		}
	}
}

# SEND_NOTICE: This sends a notice and provides something we can hook
# into for logging what the bot says for plugins and whatnot.
sub send_notice {
	my ($dest, $text) = @_;
	$text = &char_sub($text);
	$text = &Encode::encode(TARGET_ENCODING, $text);
	$kernel->post(bot => notice => $dest, $text);
    my $public = 0;
	if(@{$dest}) {
		foreach(@{$dest}) {
			if($_ =~ /[\#\&].+/) {
				$public = 1;
			}
		}
	} elsif($dest =~ /[\#\&].+/) {
		$public = 1;
	}
	&debug((3 + (!$public)), "[" . (@{$dest} ? "@{$dest}" : $dest) .
		   ":$chosen_nick] [notice] $text\n");

    if($public) {
		foreach(keys(%event_channel_notice_out)) {
			&plugin_callback($_, $event_channel_notice_out{$_}, ($chosen_nick, $dest, 'NOTICE', $text));
		}
	} else {
		foreach(keys(%event_private_notice_out)) {
			&plugin_callback($_, $event_private_notice_out{$_}, ($chosen_nick, $dest, 'NOTICE', $text));
		}
	}
}

# SEND_PIECES_WITH_NOTICE: This tells POE to run the cont_send_pieces function,
# sending the pieces as notices.
sub send_pieces_with_notice {
    my ($dest, $prefix, $text) = @_;
    $text = &char_sub($text);
    $kernel->yield('cont_send_pieces', 'NOTICE', $dest, $prefix,
                    $text);
}

# SEND_PIECES: This tells POE to run the cont_send_pieces function, below,
# sending the pieces as messages.
sub send_pieces {
    my ($dest, $prefix, $text) = @_;
    $text = &char_sub($text);
    $kernel->yield('cont_send_pieces', 'PRIVMSG', $dest, $prefix,
                    $text);
}

### cont_send_pieces
# This is called by POE to break the message up into pieces of no more
# than 440 characters. This accommodates the message length limitation
# on most IRC networks.
#
# Arguments:
#   ARG0: $type:    NOTICE to send notices, or PRIVMSG to send messages
#   ARG1: $dest:    where we are sending the message
#   ARG2: $prefix:  should something be put at the beginning of each
#                   piece?
#   ARG3: $text:    the text to split.
sub cont_send_pieces {
    my ($kernel, $type, $dest, $prefix, $text) = @_[KERNEL, ARG0, ARG1, ARG2, ARG3];
    my @words = split(/(\b | \b)/, $text);
    my $line = (defined $prefix ? $prefix . ' ' : '') . shift(@words);
    my ($curWord);

    while(@words) {
        $curWord = shift(@words);
        if($curWord =~ m/^(.*)\n(.*)$/s) {
            # curword has a line break in it
            # split the line break, and push the word after it back
            # onto the left of the array.
            # if the word before the line break fits, add it and send
            # the message.
            # if not, push the line feed and the left word back onto
            # the left of the array, and have POE call cont_send_pieces
            # again.
            my $nextWord;
            ($curWord, $nextWord) = ($1, $2);
            unshift(@words, $nextWord);
            if(length($line) + length($curWord) <= 440) {
                $line .= $curWord;
                $kernel->delay('cont_send_pieces', 1, $type, $dest, $prefix,
                               join('', @words));
            } else {
                $kernel->delay('cont_send_pieces', 1, $type, $dest, $prefix,
                               ("$curWord\n" . join('', @words)));
            }
            last;
        } elsif(length($line) + length($curWord) <= 440) {
            $line .= $curWord;
		} else {
            # next word would make the line too long.
            # tell POE to run cont_send_pieces again with the remaining
            # words.
			if ($curWord !~ m/^ +$/) {
				unshift(@words, $curWord);
			}
            $kernel->delay('cont_send_pieces', 1, $type, $dest, $prefix,
                            join('', @words));
            last;
        }
    }
	if ($type eq "NOTICE") {
		&send_notice($dest, $line);
	} else {
		&send_message($dest, $line);
	}
}

# ######### IRC FUNCTION CALLS ###########

# RUN_SCHEDULER_60: Runs events every 60 seconds.
sub run_scheduler_60 {
	my $kernel = $_[ KERNEL ];
    $kernel->post(bot => ison => @list_nicks_ison);
	$alarm_sched_60 = $kernel->delay_set('scheduler_60', 60);
}

# SERVER_ISON: Process the ISON reply from the server.  We'll use this to
# recover the bot's desired nickname if it becomes available.  Plugins can
# also add nicknames to this list and see whether or not they are online
# periodically.
sub server_ison {
    my @nicks = split(/ /, $_[ ARG1 ]);
	my $own_nick = option('global', 'nickname');
    my $avail = 1;
    &debug(DEBUG_SPAM, "Nicknames online: @nicks\n");

    foreach (@nicks) {
		if ($_ eq $own_nick) {
			$avail = 0;
		}
    }
    if ($avail == 1) {
		$kernel->post(bot => nick => $own_nick);
		&debug(DEBUG_STD, "Nickname " . $own_nick . " is available!  Attempting to recover it...\n");
		$chosen_nick = $own_nick;
    }
    foreach(keys(%event_server_ison)) {
		&plugin_callback($_, $event_server_ison{$_}, ($chosen_server, $chosen_nick, @nicks));
    }
}

# SERVER_WHO: Get the WHO command responses, which help us to keep track of
# users' hostmasks.
sub server_who {
	my (undef, $user, $host, $server, $nick) = split(/ /, $_[ ARG1 ]);
	&set_hostmask($nick, "$nick!$user\@$host");
	&debug(DEBUG_SPAM, "Caching hostmask for $nick (" . &get_hostmask($nick) . ")\n");
}

# SERVER_NO_SUCH_NICK: The server is telling us the nick or channel we just
# acted on, usually messaging or noticing a nick, does not exist.
# We use this to discard any remaining output to that nick.
sub server_no_such_nick {
    my ($nick) = split(/ /,$_[ARG1],2);
    # FIXME: I have *no* idea how to check all delayed functions and clear the
    # appropiate one.
}

# PROCESS_PING: Handle ping requests to the bot.
sub process_ping {
    my ($nick) = split(/!/, $_[ARG0]);
    my $text = $_[ ARG2 ];
    &debug(DEBUG_STD, "[ctcp] PING requested by " . $nick . ".\n");
	# We want this reply to be delivered with some urgency.
    $kernel->call(bot => ctcpreply => $nick, 'PING ' . $text);
}

# PROCESS_FINGER: Handle finger requests to the bot.
sub process_finger {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = "I have no fingers.  Please try again.";
    &debug(DEBUG_STD, "[ctcp] FINGER requested by " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'FINGER ' . $reply);
}

# PROCESS_TIME: Handle time requests to the bot.
sub process_time {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = localtime(time);
    &debug(DEBUG_STD, "[ctcp] TIME requested by " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'TIME ' . $reply);
}

# PROCESS_VERSION: Handle version requests to the bot.
sub process_version {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = join(" ", (POSIX::uname())[0, 2, 4]);
    &debug(DEBUG_STD, "[ctcp] VERSION requested by " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, "VERSION " . PROJECT . " " .
				  VERSION . " ($reply)");
}

# SERVER_NICK_CHANGE: Handle nickname changes for users we can see.
sub server_nick_change {
	my ($nick, $userhost) = split(/!/, $_[ARG0]);
	my $newnick = $_[ ARG1 ];

	&debug(DEBUG_STD, "$nick is now known as $newnick.\n");

	&debug(DEBUG_SPAM, "Uncaching hostmask for $nick (" . &get_hostmask($nick) . ")\n");
	&set_hostmask($nick, undef);
	&set_hostmask($newnick, $newnick . "!" . $userhost);
	&debug(DEBUG_SPAM, "Caching hostmask for $newnick (" . &get_hostmask($newnick) . ")\n");

    foreach(keys(%event_server_nick)) {
		&plugin_callback($_, $event_server_nick{$_}, ($chosen_server, $nick, $newnick));
    }
}

# PROCESS_NOTICE: Handle notices to the bot.
sub process_notice {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($target, $text) = @_[ ARG1, ARG2 ];
    my $public = 0;
	my $channel;
    foreach my $dest (@{$target}) {
		if($dest =~ /([\#\&].+)/) {
			$public = 1;
			$channel = $dest;
		}
    }
    if($public) {
		&debug(DEBUG_STD, "[$channel:$nick] [notice] $nick\n");
		foreach(keys(%event_channel_notice)) {
			&plugin_callback($_, $event_channel_notice{$_}, ($nick, $channel, 'NOTICE', $text));
		}
    } else {
		&debug(DEBUG_INFO, "[private:$nick] [notice] $text\n");
		foreach(keys(%event_private_notice)) {
			&plugin_callback($_, $event_private_notice{$_}, ($nick, 'NOTICE', $text));
		}
    }
}

# PROCESS_ACTION: Handle actions sent to the channel.
sub process_action {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($target, $text) = @_[ ARG1, ARG2 ];
    my $public = 0;
	my $channel;
    foreach my $dest (@{$target}) {
		if($dest =~ /[\#\&].+/) {
			$public = 1;
			$channel = $dest;
		}
    }
    if($public) {
		if (!$snooze) {
			&debug(DEBUG_INFO, "Learning from " . $nick . "'s action...\n");
			&debug(DEBUG_STD, "[$channel:$nick] [action] $nick $text\n");
			&build_records($text,"ACTION");
		}
		foreach(keys(%event_channel_action)) {
			&plugin_callback($_, $event_channel_action{$_}, ($nick, $channel, 'ACTION', $text));
		}
    } else {
		&debug(DEBUG_INFO, "[private:$nick] [action] $nick $text\n");
		foreach(keys(%event_private_action)) {
			&plugin_callback($_, $event_private_action{$_}, ($nick, 'PRIVACTION', $text));
		}
    }
}

# PRIVATE_MESSAGE: Handle private messages to the bot.
sub private_message {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my $text = $_[ ARG2 ];
	&debug(DEBUG_INFO, "[private:$nick] $text\n");
    foreach(keys(%event_private_message)) {
		&plugin_callback($_, $event_private_message{$_}, ($nick, 'PRIVMSG', $text));
    }
}

# CHANNEL_MESSAGE: Handle messages sent to the channel.
sub channel_message {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($channel, $text) = @_[ ARG1, ARG2 ];

	my $prefix = option('global', 'command_prefix');
	my $nickmatch = "(" . $chosen_nick . "|" .
		option('global', 'nickname') . "|" .
		option('global', 'alt_tag') . ")";
	$nickmatch = qr/$nickmatch/i;

	foreach(keys(%event_channel_message)) {
		&plugin_callback($_, $event_channel_message{$_}, ($nick, $channel, 'SAY', $text));
	}

	# We pass the original string to plugins.  Then, we strip out formatting
	# codes.  Who knows?  Someone might want to log things exactly as they
	# were.
    $text =~ s/\003\d{0,2},?\d{0,2}//g;
    $text =~ s/[\002\017\026\037]//g;

	&debug(DEBUG_STD, "[@{$channel}:$nick] $text\n");

    if ($text =~ /^\Q$prefix\E/) {
		my @command = split(/\s/, $text);
		my $cmd = $command[0];
		$cmd =~ s/^\Q$prefix\E//;
		if ($event_plugin_call{lc($cmd)}) {
			&plugin_callback($cmd, $event_plugin_call{lc($cmd)}, ($nick, $channel, @command));
		} else {
			if($cmd =~ m/[a-z]/i) {
				&send_message($channel, "Hmm... @command isn't supported. Try " . $prefix . "help");
			}
			# otherwise, command has no letters in it, and therefore was probably a smile %-) (a very odd smile, sure, but whatever)
		}
    } elsif ($text =~ /^hi,*\s+$nickmatch[!\.\?]*/i && !$snooze) {
		&debug(DEBUG_INFO, "Greeting " . $nick . "...\n");
		&send_message($channel, option('chat', 'greeting') . " $nick!");
    } elsif ($text =~ /(^|.[\.!\?,]+\s+)$nickmatch([\.!\?:,]+|\s*$)/i && !$snooze) {
		my $continue = 1;
		foreach(keys(%event_bot_addressed)) {
			$continue = 0 if(!&plugin_callback($_, $event_bot_addressed{$_}, ($nick, $channel, $text)));
		}

		if ($continue) {
			&debug(DEBUG_INFO, "Generating a reply for " . $nick . "...\n");
			my @botreply = split(/__NEW__/, &build_reply($text));
			my $queue = "";
			foreach my $comment (@botreply) {
				if ($comment =~ /__ACTION\s/) {
					$comment =~ s/$&//;
					&send_message($channel, $queue) unless ($queue eq "");
					&send_action($channel, $comment);
					$queue = "";
				} else {
					$queue .= $comment . " ";
				}
			}
			&send_message($channel, $queue) unless ($queue eq "");
		}
    } elsif ($text !~ /^[;=:]/ && !$snooze) {
		&debug(DEBUG_INFO, "Learning from " . $nick . "...\n");
		&build_records($text);
    }
}

# CHANNEL_KICK: If the bot is kicked, rejoin the channel.  Also let
# inquiring plugins know about kick events.
sub channel_kick {
	my ($kicker) = split(/!/, $_[ ARG0 ]);
    my ($chan, $nick, $reason) = @_[ ARG1, ARG2, ARG3 ];
	&debug(DEBUG_STD, "$nick was kicked from $chan by $kicker. ($reason)\n");

    if ($nick eq $chosen_nick && lc($chan) eq lc(option('network', 'channel'))) {
		&debug(DEBUG_WARN, "Kicked from $chan... Attempting to rejoin!\n");
		$kernel->post(bot => join => $chan);
    }
	&debug(DEBUG_SPAM, "Uncaching hostmask for $nick (" . &get_hostmask($nick) . ")\n");
	&set_hostmask($nick, undef);

    foreach(keys(%event_channel_kick)) {
		&plugin_callback($_, $event_channel_kick{$_}, ($nick, $chan, 'KICKED', $reason, $kicker));
    }
}

# CHANNEL_INVITE: Process a channel invitation from a user.
sub channel_invite {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my $chan = $_[ ARG1 ];
    foreach(keys(%event_channel_invite)) {
		&plugin_callback($_, $event_channel_invite{$_}, ($nick, $chan, 'INVITED'));
    }
    if ($chan eq option('network', 'channel')) {
		$kernel->post(bot => join => $chan);
    }
}

# CHANNEL_NOJOIN: Allow plugins to take actions on failed join attempt.
sub channel_nojoin {
    my ($chan, $msg) = split(/ :/, $_[ ARG1 ]);
	&debug(DEBUG_WARN, "Unable to join $chan. ($msg)\n");
    foreach(keys(%event_channel_nojoin)) {
		&plugin_callback($_, $event_channel_nojoin{$_}, ($chosen_nick, $chan, 'NOTJOINED', $msg));
    }
}

# CHANNEL_JOIN: Allow plugins to take actions on successful join attempt.
sub channel_join {
    my ($nick) = split(/!/, $_[ ARG0 ]);
	&set_hostmask($nick, $_[ ARG0 ]);
    my $chan = $_[ ARG1 ];

    if ($nick eq $chosen_nick) {
		&debug(DEBUG_STD, "Successfully joined $chan.\n");
		$kernel->post(bot => who => $chan);
		foreach(keys(%event_channel_mejoin)) {
			&plugin_callback($_, $event_channel_mejoin{$_}, ($nick, $chan, 'JOINED'));
		}
    } else {
		&debug(DEBUG_STD, "$nick has joined $chan.\n");
		foreach(keys(%event_channel_join)) {
			&plugin_callback($_, $event_channel_join{$_}, ($nick, $chan, 'JOINED'));
		}
    }

	&debug(DEBUG_SPAM, "Caching hostmask for $nick (" . &get_hostmask($nick) . ")\n");
}

# CHANNEL_PART: Allow plugins to take actions when a user parts the channel.
sub channel_part {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $message) = split(/ :/, $_[ ARG1 ], 2);
    &debug(DEBUG_STD, "$nick has parted $chan."
		   . (defined $message ? " ($message)" : "") . "\n");
	&debug(DEBUG_SPAM, "Uncaching hostmask for $nick (" . &get_hostmask($nick) . ")\n");
	&set_hostmask($nick, undef);
    foreach(keys(%event_channel_part)) {
		&plugin_callback($_, $event_channel_part{$_}, ($nick, $chan, 'PARTED', $message));
    }
}

# CHANNEL_QUIT: Allow plugins to take actions when a user parts the channel.
sub channel_quit {
    my $message = $_[ ARG1 ];
    my ($nick) = split(/!/, $_[ ARG0 ]);
    &debug(DEBUG_STD, "$nick has quit IRC."
		   . (defined $message ? " ($message)" : "") . "\n");
	&debug(DEBUG_SPAM, "Uncaching hostmask for $nick (" . &get_hostmask($nick) . ")\n");
	&set_hostmask($nick, undef);
    foreach(keys(%event_channel_quit)) {
		&plugin_callback($_, $event_channel_quit{$_}, ($nick, undef, 'QUIT', $message));
    }
}

# CHANNEL_NOVOICE: Allow plugins to take actions when the bot cannot speak.
sub channel_novoice {
    my ($chan) = split(/ :/, $_[ ARG1 ]);
    &debug(DEBUG_WARN, "Last message could not be sent to $chan.\n");
    foreach(keys(%event_channel_novoice)) {
		&plugin_callback($_, $event_channel_novoice{$_}, ($chosen_nick, $chan, 'CANTSAY'));
    }
}

# CHANNEL_TOPIC: Allow plugins to take actions when the topic is changed.
sub channel_topic {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $text) = @_[ ARG1, ARG2 ];
    &debug(DEBUG_STD, "Topic in $chan was changed to '$text' by $nick.\n");
    foreach(keys(%event_channel_topic)) {
		&plugin_callback($_, $event_channel_topic{$_}, ($nick, $chan, 'TOPIC', $text));
    }
}

# CHANNEL_MODE: Allow plugins to take actions when the channel modes change.
sub channel_mode {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $modes, @args) = @_[ ARG1, ARG2, ARG3 .. $#_ ];
	# If the mode change was made on the bot, it is not a channel mode.
    if ($chan ne $chosen_nick) {
		&debug(DEBUG_STD, "$nick set mode $modes @args in $chan.\n");
		foreach(keys(%event_channel_mode)) {
			&plugin_callback($_, $event_channel_mode{$_}, ($nick, $chan, 'MODE', $modes, @args));
		}
	}
}

# ######### CONNECTION SUBROUTINES ###########

# INITIALIZE: Prepares the kernel for our use and starts the first connection.
sub initialize {
	# We want to catch signals to make sure we clean up and save if the
	# system wants to kill us.  We'll use POE to deal with them for us.
	$kernel->sig( INT => 'quit_session' );
	$kernel->sig( HUP => 'quit_session' );
	$kernel->sig( TERM => 'quit_session' );
	$kernel->sig( USR1 => 'restart' );
	$kernel->sig( USR2 => 'rehash' );

    $kernel->alias_set('simbot'); # so plugins can talk back to us

	$kernel->post(bot => register => "all");

	@servers = option_list('network', 'server');

	&irc_connect;
}

# IRC_CONNECT: Creates a connection to IRC.
sub irc_connect {
    $chosen_nick = option('global', 'nickname');
    $chosen_server = pick(@servers);
    my $chosen_port = 6667;
    if($chosen_server =~ m/^(.*):(\d+)$/) {
        $chosen_server = $1;
        $chosen_port = $2;
    }

    $kernel->post(bot => 'connect',
				  {
					  Nick    => $chosen_nick,
					  Server  => $chosen_server,
					  Port    => $chosen_port,
					  Ircname => PROJECT . " " . VERSION,
					  Username => option('network', 'username'),
				  }
				  );
    &debug(DEBUG_STD, 'Connecting to IRC server ' . $chosen_server . ' on port ' . $chosen_port . "...\n");
}

# IRC_CONNECTED: After connecting to IRC, this will join the channel and
# log the bot into channel services.
sub irc_connected {
	my $channel = option('network', 'channel');

	# Start the 60 second scheduler
	$alarm_sched_60 = $kernel->delay_set('scheduler_60', 60);

    &debug(DEBUG_STD, "Setting invisible user mode...\n");
    $kernel->post(bot => mode => $chosen_nick, "+i");
    foreach(keys(%event_server_connect)) {
		&plugin_callback($_, $event_server_connect{$_}, ($chosen_server, $chosen_nick));
    }
    &debug(DEBUG_STD, "Joining $channel...\n");
    $kernel->post(bot => join => $channel);
}

# PICK_NEW_NICK: If IRC reports the desired nickname as in use, this
#                will rotate the letters in the nickname to get a new one.
sub pick_new_nick {
    &debug(DEBUG_WARN, "Nickname " . $chosen_nick . " is unavailable!  Trying another...\n");
    $chosen_nick = substr($chosen_nick, -1) . substr($chosen_nick, 0, -1);
    $kernel->post(bot => nick => $chosen_nick);
}

# IRC_DISCONNECTED: Handles the case where we are disconnected from the IRC.
# server.
sub irc_disconnected {
	$kernel->alarm_remove($alarm_sched_60);

    if ($terminating >= 1) {
		&debug(DEBUG_STD, "Disconnected!\n");
		$kernel->post(bot => unregister => "all");


        # Everyone out of the pool!
        foreach(keys(%event_plugin_unload)) {
            &plugin_callback($_, $event_plugin_unload{$_});
        }

        # remove our alias
        $kernel->alias_remove('simbot');

		# since the event loop should soon have nothing to do
		# it'll exit. Or something like that.
    } else {
		&debug(DEBUG_WARN, "Disconnected!  Reconnecting in 30 seconds...\n");
		sleep 30;
		&irc_connect;
    }
}

# SERVER_ERROR: The server's whining at us. We should listen.
sub server_error {
    &debug(DEBUG_ERR, "$_[ARG0]\n");
#    if ($_[ARG0] =~ /k-lined/i) {
#    }
}

# SERVER_NOTICE: The server has something to say. We should listen.
sub server_notice {
    &debug(DEBUG_STD, "$_[ARG0]\n");
}

# SERVER_BANNED: The server has told us you're banned, creep.
#  no, really. Numeric 465, ERR_YOUREBANNEDCREEP
sub server_banned {
    &debug(DEBUG_ERR, "Banned from $_[ARG0]: $_[ARG1]\n");

    if(!defined $chosen_server) {
        die q($chosen_server is undefined);
    }
    for (my $i = 0; defined $servers[$i]; $i++) {
        if ($chosen_server eq $servers[$i]) {
            splice(@servers, $i, 1)
        }
    }
    if(!@servers) {
        # hmm... we've removed our last server
        &debug(DEBUG_ERR, "No more servers to connect to! Please add some to config.ini.\n");
        $terminating=100;
    }

}

# SERVER_SUPPORTS: called when the server tells us some information about
# itself. Right now, we use it to figure out what network we are on
# and enable any network specific modes.
# In the future, this could be used to make any channel management features
# more efficient by configuring the number of modes that can be set at once,
# how many bans the server allows, if the server supports invite and ban
# exceptions, etc
# Also, could be used to push ignores serverside with the SILENCE command
sub server_supports {
    my ($message) = $_[ARG1] =~ m/^(.*):.*?$/;
    &debug(DEBUG_INFO, "Server supports: ${message}\n");

    foreach my $cur_block (split(/ /, $message)) {
        if(my ($ircd) = $cur_block =~ m/^IRCD=(\S+)/) {
            if($ircd =~ m/dancer/) {
                &debug(DEBUG_STD, "We're on a Dancer IRCD server, setting no-forward user mode\n");

                # +Q tells the server not to try to forward us to another
                # channel.
                # FIXME: Channel forwarding should work, or at least be handled
                # nicely. Right now many plugins assume that the channel we are
                # in is the channel defined in the config file, which may
                # not be true.
				# The changes necessary to do this will make multi-channel
				# support easier in the future.
                $kernel->post(bot => mode => $chosen_nick => '+Q');
            }

        # } elsif(my ($maxwatch) = $cur_block =~ m/^WATCH=(\d+)/) {
            # hmm... the server supports watch lists
            # let's use them instead of polling with ison

        # } elsif(my ($maxmodes) = $cur_block =~ m/^MODES=(\d+)/) {
            # This tells us how many mode changes can be done at once.
            # mode flags count as 1, arguments count as 1
            # (so +b foo counts as 2, while +i counts as 1)

        # } elsif(my ($modeflags) = $cur_block =~ m/^STATUSMSG=(\S+)/) {
            # This tells us what mode flags (+%@ etc) we can stick in front
            # of a channel name to message that channels voiced/halfops/ops
            # + means we can use +#channel to message the channel's voiced,
            # halfops, and ops. % is halfops and ops, @ is ops.

            # we should use this for any wallchops type command
            # if the server tells us it can
        }
    }
}

# SOCKET_ERROR: Spit out the error, then reconnect to IRC.
sub socket_error {
    &debug(DEBUG_ERR, "$_[ARG0]\n");
    &irc_disconnected;
}

# QUIT_SESSION: Prepares to terminate the IRC connection and exit.
sub quit_session {
    my ($kernel, $message) = @_[ KERNEL, ARG0 ];

	if ($message eq "TERM") {
		$message = "Terminated";
	} elsif ($message eq "HUP") {
		$message = "I am lost without my terminal!";
	} elsif ($message eq "INT") {
		if (option('network', 'quit_prompt')) {
			print "\nEnter Quit Message:\n";
			$message = readline(STDIN);
			chomp($message);
		} else {
			$message = option('network', 'quit_default');
		}
	}

	$terminating = 1 unless $terminating > 1;

	$kernel->post(bot => quit => PROJECT . " " . VERSION
				  . (($message ne "") ? ": $message" : ""));
	&debug(DEBUG_STD, "Disconnecting from IRC... $message\n");

    # remove any alarms. This stops any verbose output simbot was giving
    $kernel->alarm_remove_all( );

    $kernel->sig_handled();
}

# RESTART: Quits and restarts the script.  This should be done
#          after the script is updated.
sub restart {
    my ($kernel, $signal) = @_[ KERNEL, ARG0 ];
	if (defined $signal) {
		&debug(DEBUG_STD, "Restart requested via signal ($signal)...\n");
	} else {
		&debug(DEBUG_STD, "Restart requested...\n");
	}
	$terminating = 2;
    $kernel->yield(quit_session => "Restarting... brb!");

    $kernel->sig_handled();
}

# REHASH: Calls a series of reload callbacks to refresh data files.
sub rehash {
    my ($kernel, $signal) = @_[ KERNEL, ARG0 ];
	if (defined $signal) {
		&debug(DEBUG_STD, "Rehash requested via signal ($signal)...\n");
	} else {
		&debug(DEBUG_STD, "Rehash requested...\n");
	}
    foreach(keys(%event_plugin_reload)) {
		&plugin_callback($_, $event_plugin_reload{$_});
    }

    $kernel->sig_handled();
}

&debug(DEBUG_SPAM, "Starting main event loop.\n");
$kernel->run();
&debug(DEBUG_SPAM, "Exited main event loop.\n");
&save;
if ($terminating == 2) {
    &debug(DEBUG_STD, "Restarting script...\n");
	exec "./simbot.pl"
		. (defined $args{debug} ? " --debug=$args{debug}" : "")
		. (defined $args{config} ? " --config=\"$args{config}\"" : "");
} else {
    &debug(DEBUG_STD, "Terminated.\n");
	if($terminating > 2) {
	   exit $terminating; #abnormal exit
    } else {
        exit 0;
    }
}
