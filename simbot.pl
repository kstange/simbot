#!/usr/bin/perl

# SimBot
#
# Copyright (C) 2002-04, Kevin M Stange <kevin@simguy.net>
#
# This program is free software; you can redistribute it and/or modify
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
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

# Hi, my name is:
package SimBot;

# We hold our code up to some standards.  If anyone knows how to use
# symbolic refs with strict refs on, you should tell us.  From the Perl
# documentation this is decidely not possible.
use warnings;
use strict;
no strict 'refs';

use vars qw( %conf %chat_words $chosen_nick $chosen_server $POE_SESSION );

# Load the configuration file into memory.
open(CONFIG, "./config.ini") || die("Your configuration file (config.ini) is missing.");
my $section;
foreach (<CONFIG>) {
	chomp;
	if (m/^#|^\s*$/) {
	} elsif (m/^\[(.*)\]$/) {
		debug(4, "Begin config section $1.\n");
		$section = $1;
	} elsif (m/^(.*?)=(.*)$/) {
		if ($section eq "filters") {
			if ($1 eq "match") {
				push(@{$conf{'filters'}}, qr/$2/);
				debug(4, "$section: loaded match filter for $2\n");
			} elsif ($1 eq "word") {
				push(@{$conf{'filters'}}, qr/(^|\b)$2(\b|$)/);
				debug(4, "$section: loaded word filter for $2\n");
			} else {
				debug(4, "$section: saw unknown filter type $1\n");
			}
		} else {
			push(@{$conf{$section}{$1}}, "$2");
			debug(4, "$section: loaded option $1 as $2\n");
		}
	}
	}
undef $section;
close(CONFIG);

# Check some config options or bail out!
die("Your configuration is lacking an IRC server to connect to") unless option_list('network', 'server');
die("Your configuration is lacking a channel to join") unless option('network', 'channel');
die("Your configuration is lacking a valid default nickname") unless option('global', 'nickname');
die("Your configuration has an extra sentence % >= 100%") unless option('chat', 'new_sentence_chance') < 100;
die("Your configuration has no rulefile to load") unless option('global', 'rules');

# We set sane defaults for some options if necessary.
if (!option('global', 'command_prefix')) {
	$conf{'global'}{'command_prefix'}[0] = '%';
	debug(2, "global/command_prefix missing from config. Using '%'.\n");
}
if (!option('chat', 'new_sentence_chance')) {
	$conf{'chat'}{'new_sentence_chance'}[0] = 0;
	debug(2, "chat/new_sentence_chance missing from config. Using 0 (off).\n");
}
if (!option('chat', 'delete_usage_max')) {
	$conf{'chat'}{'delete_usage_max'}[0] = -1;
	debug(2, "chat/delete_usage_max missing from config. Using -1 (off).\n");
}
if (!option('network', 'username')) {
	$conf{'network'}{'username'}[0] = 'nobody';
	debug(2, "network/username missing from config. Using 'nobody'.\n");
}

# Once we know the gender, is it his or her (or its)?
if(option('global', 'gender') eq 'M') {
    our $hisher = 'his';
} elsif (option('global', 'gender') eq 'F') {
    our $hisher = 'her';
} else {
    our $hisher = 'its';
}

# ****************************************
# *********** Random Variables ***********
# ****************************************

# Error Descriptions
use constant ERROR_DESCRIPTIONS
        => ('', 'ERROR: ', 'WARNING: ', '', 'SPAM: ');

# Force debug on with this:
# 0 is silent, 1 shows errors, 2 shows warnings, 3 shows lots of fun things,
# 4 shows everything you never wanted to see.
use constant VERBOSE => 3;

# Software Name
use constant PROJECT => "SimBot";
# Software Version
use constant VERSION => "6.0 alpha";

# ****************************************
# ************ Start of Script ***********
# ****************************************

# We want to catch signals to make sure we clean up and save if the
# system wants to kill us.
#$SIG{'TERM'} = 'SimBot::quit';
#$SIG{'INT'}  = 'SimBot::quit';
#$SIG{'HUP'}  = 'SimBot::quit';
$SIG{'USR1'} = 'SimBot::restart';
$SIG{'USR2'} = 'SimBot::reload';

# These are intializations of the hash tables we'll be using for
# callbacks and plugin information.  We'll initialize the built-in
# plugins here, since there's no need to do registration checks.

# This provides the descriptions of plugins.  If a plugin has no
# defined description, it is "hidden" and will not appear in help.
our %plugin_desc = (
					"stats",   "Shows useless stats about the database.",
					"help",    "Shows this message.",
					);

# These are the events you can currently attach to.

### Plugin Events ###
# Plugin events get params:
#  (kernel)
our %event_plugin_load     = ();
our %event_plugin_reload   = ();
our %event_plugin_unload   = ();
# Call event gets params:
#  (kernel, from, channel, command string)
our %event_plugin_call     = (
						  "stats",   \&print_stats,
						  "help",    \&print_help,
						  );

# Register the delete plugin only if the option is enabled
if(option('chat', 'delete_usage_max') != -1) {
	$event_plugin_call{"delete"} = \&delete_words;
	$plugin_desc{"delete"} = "Erases a word that has been previously learned.";
}

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
our %event_channel_nojoin      = (); # eventname = NOTJOINED ()
our %event_channel_novoice     = (); # eventname = CANTSAY ()
our %event_channel_invite      = (); # eventname = INVITED ()

### Private Events ###
# Private events get params:
#  (kernel, from, eventname, text)
our %event_private_message     = (); # eventname = PRIVMSG (text)
our %event_private_message_out = (); # eventname = PRIVMSG (text)
our %event_private_action      = (); # eventname = PRIVACTION (text)
our %event_private_action_out  = (); # eventname = PRIVACTION (text)
our %event_private_notice      = (); # eventname = NOTICE (text)
our %event_private_notice_out  = (); # eventname = NOTICE (text)

### Server Events ###
# Server events get params:
#  (kernel, server, nickname, params)
our %event_server_connect  = (); # ()
our %event_server_ping     = (); # ()
our %event_server_ison     = (); # (nicks list...)

### Function Queries ###
# Function queries get params:
#  (kernel, params)
our %query_word_score      = (); # (text)

our @list_nicks_ison       = (
							  option('global', 'nickname'),
							  );

# Now that we've initialized the callback tables, let's load
# all the plugins that we can from the plugins directory.
opendir(DIR, "./plugins");
foreach my $plugin (readdir(DIR)) {
    if($plugin =~ /.*\.pl$/) {
		if($plugin =~ /^services\.(.+)\.pl$/) {
			debug(4, "$1 services plugin found.\n");
			if (option('services','type') eq $1) {
				debug(4, "$1 services plugin was selected. Attempting to load...\n");
				if (eval { require "./plugins/$plugin"; }) {
					debug(3, "$1 services plugin loaded successfully.\n");
				} else {
					debug(1, "$@");
					debug(2, "$1 service plugin did not load due to errors.\n");
				}
			} else {
				debug(4, "$1 services plugin was not selected.\n");
			}
		} elsif(eval { require "./plugins/$plugin"; }) {
			debug(3, "$plugin plugin loaded successfully.\n");
		} else {
			debug(1, "$@");
			debug(2, "$plugin plugin did not load due to errors.\n");
		}
    }
}
closedir(DIR);

# Here are some globals that should be initialized because someone
# might try to look at them before they get set to something.
our $loaded      = 0; # The rules are not loaded yet.
our $items       = 0; # We haven't seen any lines yet.
our $terminating = 0; # We are not terminating in the default case.

# Load the massive table of rules simbot will need.
&load;

# Now that everything is loaded, let's prepare to connect to IRC.
# We'll need this perl module to be able to do anything meaningful.
our $kernel = new POE::Kernel;
use POE;
use POE::Component::IRC;

# Create a new IRC connection.
POE::Component::IRC->new('bot');

# Add the handlers for different IRC events we want to know about.
POE::Session->new
	( _start           => \&make_connection,
	  irc_disconnected => \&reconnect,
	  irc_socketerr    => \&reconnect,
	  irc_433          => \&pick_new_nick,    # nickname in use
	  irc_001          => \&server_connect,   # connected
	  irc_ping         => \&server_ping,      # we can use this as a timer
	  irc_303          => \&server_ison,      # check ison reply
	  irc_msg          => \&private_message,
	  irc_public       => \&channel_message,
	  irc_kick         => \&channel_kick,
	  irc_join         => \&channel_join,
	  irc_part         => \&channel_part,
	  irc_quit         => \&channel_quit,
	  irc_404          => \&channel_novoice,  # we can't speak for some reason
	  irc_471          => \&channel_nojoin,   # channel is at limit
	  irc_473          => \&channel_nojoin,   # channel invite only
	  irc_474          => \&channel_nojoin,   # banned from channel
	  irc_475          => \&channel_nojoin,   # bad channel key
	  irc_invite       => \&channel_invite,
	  irc_topic        => \&channel_topic,
	  irc_mode         => \&channel_mode,
	  irc_notice       => \&process_notice,
	  irc_ctcp_action  => \&process_action,
	  irc_ctcp_version => \&process_version,
	  irc_ctcp_time    => \&process_time,
	  irc_ctcp_finger  => \&process_finger,
	  irc_ctcp_ping    => \&process_ping,
	  
	  cont_send_pieces => \&cont_send_pieces,
	  quit_session     => \&quit_session,
	  );

# ****************************************
# ********* Start of Subroutines *********
# ****************************************

# ########### GENERAL PURPOSE ############

# DEBUG: Print out messages with the desired verbosity.
sub debug {
    if ($_[0] <= VERBOSE) {
		print STDERR (ERROR_DESCRIPTIONS)[$_[0]] . $_[1];
    }
}

# PICK: Pick a random item from an array.
sub pick {
    return @_[int(rand()*@_)];
}

# HOSTMASK: Generates a 'type 3' hostmask from a nick!user@host address
sub hostmask {
    my ($nick, $user, $host) = split(/[@!]/, $_);
    if ($host =~ /(\d{1,3}\.){3}\d{1,3}/) {
		$host =~ s/(\.\d{1,3}){2}$/\.\*/;
    } else {
		$host =~ /^(.*)(\.\w*?\.[\w\.]{3,5})$/;
		$host = "*$2";
    }
    $user =~ s/^~?/*/;
    return "*!$user\@$host";
}

# PARSE_style: Parses a string for color codes
# and turns them into color and style.
sub parse_style {
    $_ = $_[0];
    # \003 begins a color. Avoid using black and white, as the window
    # will likely be either white or black, and you don't know which

    s/%white%/\0030/g;           # white
    s/%black%/\0031/g;           # black
    s/%navy%/\0032/g;            # navy
    s/%green%/\0033/g;           # green
    s/%red%/\0034/g;             # red
    s/%maroon%/\0035/g;          # maroon
    s/%purple%/\0036/g;          # purple
    s/%orange%/\0037/g;          # orange
    s/%yellow%/\0038/g;          # yellow
    s/%l(igh)?tgreen%/\0039/g;   # light green (ltgreen, lightgreen)
    s/%teal%/\00310/g;           # teal
    s/%cyan%/\00311/g;           # cyan
    s/%blue%/\00312/g;           # blue
    s/%magenta%/\00313/g;        # magenta
    s/%gray%/\00314/g;           # gray
    s/%silver%/\00315/g;         # silver

    s/%normal%/\017/g;           # normal - remove color and style

    s/%bold%/\002/g;             # bold
    s/%u(nder)?line%/\037/g;     # underline (uline)


    return $_;
}

# TIMEAGO: Returns a string of how long ago something happened
sub timeago {
    my ($seconds, $minutes, $hours, $days, $weeks, $years);
    $seconds = time - $_[0];
    if($seconds >= 60) {
        $minutes = int $seconds / 60;
        $seconds %= 60;
        if($minutes >= 60) {
            $hours = int $minutes / 60;
            $minutes %= 60;
            if($hours >= 24) {
                $days = int $hours / 24;
                $hours %= 24;
                if($days >= 365) {
                    $years = int $days/365;
                    $days %= 365;
                }
            }
        }
    }

    my @reply;
    push(@reply, "$years year" . (($years == 1) ? '' : 's'))       if $years;
    push(@reply, "$days day" . (($days == 1) ? '' : 's'))          if $days;
    push(@reply, "$hours hour" . (($hours == 1) ? '' : 's'))       if $hours;
    push(@reply, "$minutes minute" . (($minutes == 1) ? '' : 's')) if $minutes;
    push(@reply, "$seconds second" . (($seconds == 1) ? '' : 's')) if $seconds;
    if(@reply) {
		my $string = join(', ', @reply) . ' ago';
		$string =~ s/(.*),/$1 and/;
		return $string;
	} else {
		return 'very recently';
    }
}

# OPTION: Returns the value (or a random value from a list) for a
# for a particular option.
sub option {
	my ($sec, $val) = @_;
	return "" if (!defined $conf{$sec} || !defined $conf{$sec}{$val});
	return pick(@{$conf{$sec}{$val}});
}

# OPTION_LIST: Returns a list of the values set for a particular option.
sub option_list {
	my ($sec, $val) = @_;
	return () if !defined $conf{$sec};
	if ($sec eq "filters") {
		return @{$conf{$sec}};
	} else {
		return () if (!defined $conf{$sec}{$val});
		return @{$conf{$sec}{$val}};
	}
}

# RESTART: Quits and restarts the script.  This should be done
#          after the script is updated.
sub restart {
    &debug(3, "Received restart call...\n");
	$terminating = 2;
    &quit("Restarting, brb...");
}

# RELOAD: Calls a series of reload callbacks to refresh plugins' data.
sub reload {
    &debug(3, "Received reload call...\n");
    foreach(keys(%event_plugin_reload)) {
		&plugin_callback($_, $event_plugin_reload{$_});
    }
}

# ########### FILE OPERATIONS ############

# LOAD: This will load our rules.
sub load {
	my $rulefile = option('global', 'rules');
    &debug(3, "Loading $rulefile... ");
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
		&debug(3, "Rules loaded successfully!\n");
		$loaded = 1;
    } elsif (!-e $rulefile) {
		&debug(2, "File does not exist and will be created on save.\n");
		$loaded = 1;
    } else {
		&debug(1, "Cannot read from the rules file! This session will not be saved!\n");
    }
}

# SAVE: This will save our rules.
sub save {
	my $rulefile = option('global', 'rules');
    &debug(3, "Saving $rulefile... ");
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
			&debug(3, "Rules saved successfully!\n");
		} else {
			&debug(1, "Cannot write to the rules file! This session will be lost!\n");
		}
    } else {
		&debug(2, "Opting not to save.  Rules are not loaded.\n");
    }
    $items = 0;
}

# ########### PLUGIN OPERATIONS ############

# PLUGIN_REGISTER: Registers a plugin (or doesn't).
sub plugin_register {
    my %data = @_;
    if ($data{modules}) {
		foreach (split(/,/, $data{modules})) {
			if (eval { eval "require $_"; }) {
				&debug(4, $data{plugin_id} . ": $_ module was loaded as a plugin dependency\n");
			} else {
				&debug(1, $data{plugin_id} . ": $_ module could not be loaded as a plugin dependency\n");
				die("$data{plugin_id}: the plugin is missing dependencies");
			}
		}
    }
    if(!$event_plugin_call{$data{plugin_id}}) {
		&debug(4, $data{plugin_id} . ": no plugin conflicts detected\n");
    } else {
		die("$data{plugin_id}: a plugin is already registered to this handle");
    }
    $event_plugin_call{$data{plugin_id}} = $data{event_plugin_call};
    if(!$data{plugin_desc}) {
		&debug(4, $data{plugin_id} . ": this plugin has no description and will be hidden\n");
    } else {
		$plugin_desc{$data{plugin_id}} = $data{plugin_desc};
    }
    if ($data{event_plugin_load}) {
		if (!&plugin_callback($data{plugin_id}, $data{event_plugin_load})) {
			die("$data{plugin_id}: the plugin returned an error on load");
		}
		$event_plugin_load{$data{plugin_id}} = $data{event_plugin_load};

    }
    if ($data{event_plugin_unload}) {
		$event_plugin_unload{$data{plugin_id}} = $data{event_plugin_unload};
    }
    if ($data{event_plugin_reload}) {
		$event_plugin_reload{$data{plugin_id}} = $data{event_plugin_reload};
    }
    foreach (keys(%data)) {
		if ($_ =~ /^event_(channel|private|server)_.*/) {
			$$_{$data{plugin_id}} = $data{$_};
		} elsif ($_ =~ /^query_.*/) {
			$$_{$data{plugin_id}} = $data{$_};
        } elsif ($_ =~ /^list_.*/) {
			my @list = split(/,\s*/, $data{$_});
			push(@{$_}, @list);
        }
    }
    return 1;
}

# PLUGIN_CALLBACK: Calls the given plugin function with paramters.
sub plugin_callback {
    my ($plugin, $function, @params) = @_;
	debug(4, "Running callback to $function in $plugin.\n");
	return &$function($kernel, @params);
}

# PRINT_HELP: Prints a list of valid commands privately to the user.
sub print_help {
    my $nick = $_[1];
	my $prefix = option('global', 'command_prefix');
	my $message = '';
    &debug(3, "Received help command from " . $nick . ".\n");
    foreach(sort {$a cmp $b} keys(%plugin_desc)) {
        $message .= "${prefix}$_ - $plugin_desc{$_}\n";
#		&send_message($nick, $prefix . $_ . " - " . $plugin_desc{$_});
    }
    chomp $message;
    &send_pieces($nick, undef, $message);
}

# PRINT_STATS: Prints some useless stats about the bot to the channel.
sub print_stats {
    my $channel = $_[2];
    my (@ldeadwords, @rdeadwords) = ();
    my ($message, $wordpop);
    my ($lfound, $lcount, $rfound, $rcount, $wordpopcount) = (0, 0, 0, 0, 0);

    &debug(3, "Received stats command from a user.\n");
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
		&send_message($channel, "There are $rcount words that lead me to unexpected dead ends. They are: @rdeadwords");
    }
    if ($lcount > 0) {
		&send_message($channel, "There are $lcount words that lead me to unexpected dead beginnings.  They are: @ldeadwords");
    }
}

# DELETE_WORDS: This removes a word, if it hasn't been deeply ingrained
# in the database (used a lot) and tells the user what has been done.
sub delete_words {
    my (undef, $nick, $channel, undef, $word) = @_;
	my $max = option('chat', 'delete_usage_max');
	$word = lc($word);
	if (defined $word) {
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
    my ($sec) = localtime(time);
    $items++;

    my $tail = -1;
    while ($sentence[$tail] =~ /^[:;=].*/) {
        $tail--;
    }
    $sentence[$tail] =~ /([\!\?])[^\!\?]*$/;
    my $startblock = "__" . ($1 ? $1 : "") . "BEGIN";
    my $endblock = "__END";

    for(my $x=0; $x <= $#sentence; $x++) {
		$sentence[$x] =~ s/^[;:].*//;
		$sentence[$x] =~ s/^=[^=]+//;
		$sentence[$x] =~ s/[^\300-\377\w\'\/\-\.=\%\$&\+\@]*//g;
		$sentence[$x] =~ s#(^|\s)\.+|\.+(\s|$)##g;
		$sentence[$x] = lc($sentence[$x]);
		if ("@sentence" !~ /[A-Za-z0-9\300-\377]/) {
			&debug(2, "This line contained no discernable words: @sentence\n");
			goto skiptosave;
		}
		foreach (option_list('filters')) {
			if ($sentence[$x] =~ /$_/) {
				&debug(2, "Not recording this line: @sentence\n");
				goto skiptosave;
			}
		}
    }

    if ("@sentence" =~ /^\s*$/) {
		&debug(2, "This line contained no discernable words: @sentence\n");
		goto skiptosave;
    }
    if ($action eq "ACTION") {
		@sentence = ("__ACTION", @sentence);
    }
    @sentence = ($startblock, @sentence, $endblock);
    my $i = 0;
    while ($i < $#sentence) {
		if($sentence[$i+1] ne "") {
			my $cur_word = $sentence[$i];
			my $y = 0;
			while ($cur_word eq "") {
				$y++;
				$cur_word = $sentence[$i-$y];
			}
			if ($chat_words{$cur_word}{$sentence[$i+1]}[1]) {
				$chat_words{$cur_word}{$sentence[$i+1]}[1]++;
				$chat_words{$sentence[$i+1]}{$cur_word}[0]++;
				&debug(3, "Updating $cur_word-\>$sentence[$i+1] to " . $chat_words{$cur_word}{$sentence[$i+1]}[1] . "\n");
				&debug(4, "Updating $sentence[$i+1]-\>$cur_word to " . $chat_words{$sentence[$i+1]}{$cur_word}[0] . " (reverse)\n");
			} else {
				$chat_words{$cur_word}{$sentence[$i+1]}[1] = 1;
				$chat_words{$sentence[$i+1]}{$cur_word}[0] = 1;
				&debug(3, "Adding $cur_word-\>$sentence[$i+1]\n");
				&debug(4, "Adding $sentence[$i+1]-\>$cur_word (reverse)\n");
			}
		}
		$i++;
    }
  skiptosave:
    if (($sec % 30) == 0 || $items >= 20) {
		&save;
    }
}

# BUILD_REPLY: This creates a random reply from the database.
sub build_reply {
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
							debug(3, "Using '$1' from __BEGIN\n");
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
				debug(4, "$chcount choices for next to $newword\n");
			}
			my $try = int(rand()*($chcount))+1;
			foreach(keys(%{$chat_words{$newword}})) {
				$try -= $chat_words{$newword}{$_}[1] if defined $chat_words{$newword}{$_}[1];
				if ($try <= 0) {
					debug(4, "Selected $_ to follow $newword\n");
					$newword = $_;
					if($newword =~ /^__([\!\?])?END$/) {
						if ($1 && !$punc) {
							$punc = $1;
							debug(3, "Using '$1' from __END\n");
						}
					} else {
						$return .= $newword . " ";
					}
					last;
				}
			}
			if ($try > 0) {
				$newword = "__END";
				&debug(1, "Database problem!  Hit a dead end in \"$return\"...\n");
			}
		} # ENDS while

		if($middleword) {
			$newword = $middleword;
			while ($newword !~ /^__[\!\?]?BEGIN$/) {
				my $chcount = 0;
				foreach (keys(%{$chat_words{$newword}})) {
					$chcount += $chat_words{$newword}{$_}[0] if defined $chat_words{$newword}{$_}[0];
				}
				debug(4, "$chcount choices for next to $newword\n");
				my $try = int(rand()*($chcount))+1;
				foreach(keys(%{$chat_words{$newword}})) {
					$try -= $chat_words{$newword}{$_}[0] if defined $chat_words{$newword}{$_}[0];
					if ($try <= 0) {
						debug(4, "Selected $_ to follow $newword\n");
						$newword = $_;
						if($newword =~ /^__([\!\?])?BEGIN$/) {
							if ($1) {
								$punc = $1;
								debug(3, "Using '$1' from __BEGIN\n");
							}
						} else {
							$return = $newword . " " . $return;
						}
						last;
					}
				}
				if ($try > 0) {
					$newword = "__BEGIN";
					&debug(1, "Database problem!  Hit a dead beginning in \"$return\"...\n");
				}
			} # ENDS while
		}
		$return =~ s/\s+$//;
		$return = uc(substr($return, 0,1)) . substr($return, 1) . ($punc ne "" ? $punc : ".");
		$return =~ s/\bi(\b|\')/I$1/g;
		my $chance = option('chat', 'new_sentence_chance');
		if ($chance && int(rand()*(100/$chance)) == 0) {
			&debug(3, "Adding another sentence...\n");
			$return .= "__NEW__" . &build_reply("");
		}
		return $return;
    } else {
		&debug(1, "Could not form a reply.\n");
		return "I'm speechless.";
    }
}

# FIND_INTERESTING_WORD: Finds a word to base a sentence off
sub find_interesting_word {
	my ($curWordScore, $highestScoreWord, $highestScore, $curWord);
	my $nickmatch = "^(" . $chosen_nick . "|" .
		option('global', 'nickname') . "|" .
		option('global', 'alt_tag') . ")\$";

	debug(3, "Word scores: ");
    $highestScoreWord = ""; $highestScore=0;
	foreach my $curWord (@_) {
        $curWord = lc($curWord);
        $curWord =~ s/[,\.\?\!\:]*$//;
        if(length($curWord) <= 3
		   || !defined $chat_words{$curWord}
           || $curWord =~ /$nickmatch/i) {
            next;
        }
        $curWordScore = 5000;
		foreach(keys(%query_word_score)) {
			$curWordScore += &plugin_callback($_, $query_word_score{$_}, ($curWord));
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
        debug(3, "$curWord:$curWordScore ");
        if($curWordScore > $highestScore) {
            $highestScore = $curWordScore;
            $highestScoreWord = $curWord;
        }
    }
    debug(3, "\nUsing $highestScoreWord\n");
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
		&debug(4, "delete: $word has been seen $use_left or $use_right times\n");
		if($count == 0 || ($use_left <= $count && $use_right <= $count)) {
			foreach my $next (keys(%{$chat_words{$word}})) {
				if ($next eq $word) {
					&debug(4, "delete: skipped a loop from $word to $next\n");
					next;
				}

				my $loop = 0;
				foreach(@path_words) {
					if($next eq $_) {
						&debug(4, "delete: skipped a loop from $word to $next\n");
						$loop = 1;
						last;
					}
				}
				next if $loop == 1;

				if (defined $chat_words{$next}{$word}
					&& keys(%{$chat_words{$next}}) <= 2) {
					push(@deleted, &delete_word($next, 0, (@path_words, $word)));
				} else {
					&debug(4, "delete: a reference from $word to $next was deleted from the database\n");
					delete($chat_words{$next}{$word});
				}
			}
			&debug(3, "delete: $word was deleted from the database\n");
			delete($chat_words{$word});
			push(@deleted, $word);
			return (@deleted);
		} else {
			&debug(3, "delete: $word was NOT deleted from the database\n");
			return (@deleted);
		}
	} else {
		&debug(4, "delete: $word ... no such word is known\n");
		return (@deleted);
	}
}

# SEND_MESSAGE: This sends a message and provides something we can hook
# into for logging what the bot says for plugins and whatnot.
sub send_message {
	my ($dest, $text) = @_;
	$kernel->post(bot => privmsg => $dest, $text);
	&debug(4, "sending message to @{$dest}\n");
    my $public = 0;
    foreach(@{$dest}) {
		if($_ =~ /[\#\&].+/) {
			$public = 1;
		}
    }
    if($public) {
		foreach(keys(%event_channel_message_out)) {
			&plugin_callback($_, $event_channel_message_out{$_}, ($chosen_nick, $dest, 'SAY', $text));
		}
	} else {
		foreach(keys(%event_private_message_out)) {
			&plugin_callback($_, $event_private_message_out{$_}, ($chosen_nick, 'PRIVMSG', $text));
		}
	}
}

# SEND_ACTION: This sends an action and provides something we can hook
# into for logging what the bot says for plugins and whatnot.
sub send_action {
	my ($dest, $text) = @_;
	$kernel->post(bot => ctcp => $dest, 'ACTION', $text);
	&debug(4, "sending action to @{$dest}\n");
    my $public = 0;
    foreach(@{$dest}) {
		if($_ =~ /[\#\&].+/) {
			$public = 1;
		}
    }
    if($public) {
		foreach(keys(%event_channel_message_out)) {
			&plugin_callback($_, $event_channel_action_out{$_}, ($chosen_nick, $dest, 'ACTION', $text));
		}
	} else {
		foreach(keys(%event_private_message_out)) {
			&plugin_callback($_, $event_private_action_out{$_}, ($chosen_nick, 'PRIVACTION', $text));
		}
	}
}

# SEND_NOTICE: This sends a notice and provides something we can hook
# into for logging what the bot says for plugins and whatnot.
sub send_notice {
	my ($dest, $text) = @_;
	$kernel->post(bot => notice => $dest, $text);
	&debug(4, "sending notice to @{$dest}\n");
    my $public = 0;
    foreach(@{$dest}) {
		if($_ =~ /[\#\&].+/) {
			$public = 1;
		}
    }
    if($public) {
		foreach(keys(%event_channel_notice_out)) {
			&plugin_callback($_, $event_channel_notice_out{$_}, ($chosen_nick, $dest, 'NOTICE', $text));
		}
	} else {
		foreach(keys(%event_private_notice_out)) {
			&plugin_callback($_, $event_private_notice_out{$_}, ($chosen_nick, 'NOTICE', $text));
		}
	}
}

# SEND_PIECES: This tells POE to run the cont_send_pieces function, below
sub send_pieces {
    my ($dest, $prefix, $text) = @_;
    $kernel->yield('cont_send_pieces', $dest, $prefix,
                    $text);
}

### cont_send_pieces
# This is called by POE to break the message up into pieces of no more
# than 440 characters. This accommodates the message length limitation
# on most IRC networks.
#
# Arguments:
#   ARG0: $dest:    where we are sending the message
#   ARG1: $prefix:  should something be put at the beginning of each
#                   piece?
#   ARG2: $text:    the text to split.
sub cont_send_pieces {
    my ($kernel, $dest, $prefix, $text) = @_[KERNEL, ARG0, ARG1, ARG2];
    my @words = split(/ +/, $text);
    my $line = ($prefix ? $prefix . ' ' : '') . shift(@words);
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
                $line .= ' ' . $curWord;
                $kernel->yield('cont_send_pieces', $dest, $prefix,
                               join(' ', @words));
            } else {
                $kernel->yield('cont_send_pieces', $dest, $prefix,
                               ("$curWord\n" . join(' ', @words)));
            }
            last;
        } elsif(length($line) + length($curWord) <= 440) {
            $line .= ' ' . $curWord;
        } else {
            # next word would make the line too long.
            # tell POE to run cont_send_pieces again with the remaining
            # words.
            unshift(@words, $curWord);
            $kernel->yield('cont_send_pieces', $dest, $prefix,
                            join(' ', @words));
            last;
        }
    }
    &send_message($dest, $line);
}

# ######### IRC FUNCTION CALLS ###########

# SERVER_CONNECT: After connecting to IRC, this will join the channel and
# log the bot into channel services.
sub server_connect {
	my $channel = option('network', 'channel');
    &debug(3, "Setting invisible user mode...\n");
    $kernel->post(bot => mode => $chosen_nick, "+i");
    foreach(keys(%event_server_connect)) {
		&plugin_callback($_, $event_server_connect{$_}, ($chosen_server, $chosen_nick));
    }
    &debug(3, "Joining $channel...\n");
    $kernel->post(bot => join => $channel);
}

# SERVER_PING: Allow for certain processes to be run on a regular IRC event,
# the ping event.
sub server_ping {
    foreach(keys(%event_server_ping)) {
		&plugin_callback($_, $event_server_ping{$_}, ($chosen_server, $chosen_nick));
    }
    $kernel->post(bot => ison => @list_nicks_ison);
}

# SERVER_ISON: Process the ISON reply from the server.  We'll use this to
# recover the bot's desired nickname if it becomes available.  Plugins can
# also add nicknames to this list and see whether or not they are online
# periodically.
sub server_ison {
    my @nicks = split(/ /, $_[ ARG1 ]);
	my $own_nick = option('global', 'nickname');
    my $avail = 1;
    &debug(4, "Nicknames online: @nicks\n");

    foreach (@nicks) {
		if ($_ eq $own_nick) {
			$avail = 0;
		}
    }
    if ($avail == 1) {
		$kernel->post(bot => nick => $own_nick);
		&debug(3, "Nickname " . $own_nick . " is available!  Attempting to recover it...\n");
		$chosen_nick = $own_nick;
    }
    foreach(keys(%event_server_ison)) {
		&plugin_callback($_, $event_server_ison{$_}, ($chosen_server, $chosen_nick, @nicks));
    }
}

# PROCESS_PING: Handle ping requests to the bot.
sub process_ping {
    my ($nick) = split(/!/, $_[ARG0]);
    my $text = $_[ ARG2 ];
    &debug(3, "Received ping request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'PING ' . $text);
}

# PROCESS_FINGER: Handle ping requests to the bot.
sub process_finger {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = "I have no fingers.  Please try again.";
    &debug(3, "Received finger request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'FINGER ' . $reply);
}

# PROCESS_TIME: Handle ping requests to the bot.
sub process_time {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = localtime(time);
    &debug(3, "Received time request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, 'TIME ' . $reply);
}

# PROCESS_VERSION: Handle ping requests to the bot.
sub process_version {
    my ($nick) = split(/!/, $_[ARG0]);
    my $reply = `uname -s -r -m`;
    chomp($reply);
    &debug(3, "Received version request from " . $nick . ".\n");
    $kernel->post(bot => ctcpreply => $nick, "VERSION " . PROJECT . " " .
				  VERSION . " ($reply)");
}

# PROCESS_NOTICE: Handle notices to the bot.
sub process_notice {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($target, $text) = @_[ ARG1, ARG2 ];
    my $public = 0;
	my $channel;
    foreach(@{$target}) {
		if($_ =~ /([\#\&].+)/) {
			$public = 1;
			$channel = $1;
		}
    }
    if($public) {
		&debug(4, "Received public notice from $nick.\n");
		foreach(keys(%event_channel_notice)) {
			&plugin_callback($_, $event_channel_notice{$_}, ($nick, $channel, 'NOTICE', $text));
		}
    } else {
		&debug(4, "Received private notice from $nick.\n");
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
    foreach(@{$target}) {
		if($_ =~ /[\#\&].+/) {
			$public = 1;
			$channel = $1;
		}
    }
    if($public) {
		&debug(3, "Learning from " . $nick . "'s action...\n");
		&build_records($text,"ACTION");
		foreach(keys(%event_channel_action)) {
			&plugin_callback($_, $event_channel_action{$_}, ($nick, $channel, 'ACTION', "$nick $text"));
		}
    } else {
		debug(4, "Received private action from $nick.\n");
		foreach(keys(%event_private_action)) {
			&plugin_callback($_, $event_private_action{$_}, ($nick, 'PRIVACTION', "$nick $text"));
		}
    }
}

# PRIVATE_MESSAGE: Handle private messages to the bot.
sub private_message {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my $text = $_[ ARG2 ];
    foreach(keys(%event_private_message)) {
		&plugin_callback($_, $event_private_message{$_}, ($nick, 'PRIVMSG', $text));
    }
}

# CHANNEL_MESSAGE: Handle messages sent to the channel.
sub channel_message {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($channel, $text) = @_[ ARG1, ARG2 ];
    $text =~ s/\003\d{0,2},?\d{0,2}//g;
    $text =~ s/[\002\017\026\037]//g;
	my $prefix = option('global', 'command_prefix');
	my $nickmatch = "(" . $chosen_nick . "|" .
		option('global', 'nickname') . "|" .
		option('global', 'alt_tag') . ")";
	$nickmatch = qr/$nickmatch/i;

	foreach(keys(%event_channel_message)) {
		&plugin_callback($_, $event_channel_message{$_}, ($nick, $channel, 'SAY', $text));
	}

    if ($text =~ /^$prefix/) {
		my @command = split(/\s/, $text);
		my $cmd = $command[0];
		$cmd =~ s/^$prefix//;
		if ($event_plugin_call{$cmd}) {
			&plugin_callback($cmd, $event_plugin_call{$cmd}, ($nick, $channel, @command));
		} else {
			if($cmd =~ m/[a-z]/) {
				&send_message($channel, "Hmm... @command isn't supported. Try " . $prefix . "help");
			}
			# otherwise, command has no letters in it, and therefore was probably a smile %-) (a very odd smile, sure, but whatever)
		}
    } elsif ($text =~ /^hi,*\s+$nickmatch[!\.\?]*/i) {
		&debug(3, "Greeting " . $nick . "...\n");
		&send_message($channel, option('chat', 'greeting') . " $nick!");
    } elsif ($text =~ /^$nickmatch([,|:]\s+|[!\?]*\s*([;:=][\Wdpo]*)?$)|,\s+$nickmatch[,!\.\?]+\s+|,\s+$nickmatch[!\.\?]*\s*([;:=][\Wdpo]*)?$/i) {
		&debug(3, "Generating a reply for " . $nick . "...\n");
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

    } elsif ($text !~ /^[;=:]/) {
		&debug(3, "Learning from " . $nick . "...\n");
		&build_records($text);
    }
}

# CHANNEL_KICK: If the bot is kicked, rejoin the channel.  Also let
# inquiring plugins know about kick events.
sub channel_kick {
	my ($kicker) = split(/!/, $_[ ARG0 ]);
    my ($chan, $nick, $reason) = @_[ ARG1, ARG2, ARG3 ];
    if ($nick eq $chosen_nick && $chan eq option('network', 'channel')) {
		&debug(2, "Kicked from $chan... Attempting to rejoin!\n");
		$kernel->post(bot => join => $chan);
    }

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
    my ($chan) = split(/ :/, $_[ ARG1 ]);
    foreach(keys(%event_channel_nojoin)) {
		&plugin_callback($_, $event_channel_nojoin{$_}, ($chosen_nick, $chan, 'NOTJOINED'));
    }
}

# CHANNEL_JOIN: Allow plugins to take actions on successful join attempt.
sub channel_join {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my $chan = $_[ ARG1 ];
    if ($nick eq $chosen_nick) {
		&debug(3, "Successfully joined $chan.\n");
		foreach(keys(%event_channel_mejoin)) {
			&plugin_callback($_, $event_channel_mejoin{$_}, ($nick, $chan, 'JOINED'));
		}
    } else {
		&debug(4, "$nick has joined $chan.\n");
		foreach(keys(%event_channel_join)) {
			&plugin_callback($_, $event_channel_join{$_}, ($nick, $chan, 'JOINED'));
		}
    }
}

# CHANNEL_PART: Allow plugins to take actions when a user parts the channel.
sub channel_part {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $message) = split(/ :/, $_[ ARG1 ], 2);
    &debug(4, "$nick has parted $chan."
		   . (defined $message ? " ($message)" : "") . "\n");
    foreach(keys(%event_channel_part)) {
		&plugin_callback($_, $event_channel_part{$_}, ($nick, $chan, 'PARTED', $message));
    }
}

# CHANNEL_QUIT: Allow plugins to take actions when a user parts the channel.
sub channel_quit {
    my $message = $_[ ARG1 ];
    my ($nick) = split(/!/, $_[ ARG0 ]);
    &debug(4, "$nick has quit IRC."
		   . (defined $message ? " ($message)" : "") . "\n");
    foreach(keys(%event_channel_quit)) {
		&plugin_callback($_, $event_channel_quit{$_}, ($nick, undef, 'QUIT', $message));
    }
}

# CHANNEL_NOVOICE: Allow plugins to take actions when the bot cannot speak.
sub channel_novoice {
    my ($chan) = split(/ :/, $_[ ARG1 ]);
    &debug(2, "Last message could not be sent to $chan.\n");
    foreach(keys(%event_channel_novoice)) {
		&plugin_callback($_, $event_channel_novoice{$_}, ($chosen_nick, $chan, 'CANTSAY'));
    }
}

# CHANNEL_TOPIC: Allow plugins to take actions when the topic is changed.
sub channel_topic {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $text) = @_[ ARG1, ARG2 ];
    &debug(4, "Topic in $chan was changed to '$text' by $nick.\n");
    foreach(keys(%event_channel_topic)) {
		&plugin_callback($_, $event_channel_topic{$_}, ($nick, $chan, 'TOPIC', $text));
    }
}

# CHANNEL_MODE: Allow plugins to take actions when the channel modes change.
sub channel_mode {
    my ($nick) = split(/!/, $_[ ARG0 ]);
    my ($chan, $modes, @args) = @_[ ARG1, ARG2, ARG3 .. $#_ ];
    if ($nick ne $chan) {
		&debug(4, "$nick set mode $modes @args in $chan.\n");
		foreach(keys(%event_channel_mode)) {
			&plugin_callback($_, $event_channel_mode{$_}, ($nick, $chan, 'MODE', $modes, @args));
		}
	}
}

# ######### CONNECTION SUBROUTINES ###########

sub quit_session {
    my($kernel, $message) = @_[ KERNEL, ARG0 ];
    if($terminating < 1) {
        
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
        $terminating = 1 unless $terminating == 2;
    
    	# Everyone out of the pool!
    	foreach(keys(%event_plugin_unload)) {
    		&plugin_callback($_, $event_plugin_unload{$_});
    	}
    
        $kernel->post(bot => quit => PROJECT . " " . VERSION
    				  . (($message ne "") ? ": $message" : ""));
        &debug(3, "Disconnecting from IRC... $message\n");
    } else {
        # somebody's impatient today
        $kernel->alarm_remove_all();
    }
    $kernel->sig_handled();
}

# QUIT: Quit IRC.
sub quit {
    if($terminating < 1) {
        
        my ($message) = @_;
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
        $terminating = 1 unless $terminating == 2;
    
    	# Everyone out of the pool!
    	foreach(keys(%event_plugin_unload)) {
    		&plugin_callback($_, $event_plugin_unload{$_});
    	}
    
        $kernel->post(bot => quit => PROJECT . " " . VERSION
    				  . (($message ne "") ? ": $message" : ""));
        &debug(3, "Disconnecting from IRC... $message\n");
    } else {
        $kernel->yield('quit_session');
    }
}

# RECONNECT: Reconnect to IRC when disconnected.
sub reconnect {
    if ($terminating >= 1) {
		&debug(2, "Disconnected!\n");
		$kernel->post(bot => unregister => "all");

		# since the event loop should soon have nothing to do
		# it'll exit. Or something like that.
    } else {
		&debug(2, "Disconnected!  Reconnecting in 30 seconds...\n");
		$chosen_server = option('network', 'server');
		sleep 30;
		$kernel->post(bot => 'connect',
					  {
						  Nick    => $chosen_nick,
						  Server  => $chosen_server,
						  Port    =>  6667,
						  Ircname => PROJECT . " " . VERSION,
						  Username => option('network', 'username'),
					  }
					  );
		&debug(3, "Connecting to IRC server " . $chosen_server . "...\n");
    }
}

# MAKE_CONNECTION: Starts up the connection to IRC.
sub make_connection {
    &debug(3, "Setting up the IRC connection...\n");

    $kernel->sig( INT => 'quit_session' );
    $kernel->sig( HUP => 'quit_session' );
    $kernel->sig( TERM => 'quit_session' );
    
    $kernel->post(bot => register => "all");
    $chosen_nick = option('global', 'nickname');

    $chosen_server = option('network', 'server');
    $kernel->post(bot => 'connect',
				  {
					  Nick    => $chosen_nick,
					  Server  => $chosen_server,
					  Port    =>  6667,
					  Ircname => PROJECT . " " . VERSION,
					  Username => option('network', 'username'),
				  }
				  );
    &debug(3, "Connecting to IRC server " . $chosen_server . "...\n");
}

# PICK_NEW_NICK: If IRC reports the desired nickname as in use, this
#                will rotate the letters in the nickname to get a new one.
sub pick_new_nick {
    &debug(2, "Nickname " . $chosen_nick . " is unavailable!  Trying another...\n");
    $chosen_nick = substr($chosen_nick, -1) . substr($chosen_nick, 0, -1);
    $kernel->post(bot => nick => $chosen_nick);
}

$kernel->run();
&debug(3, "Exited event loop!\n");
&save;
if ($terminating == 2) {
    &debug(3, "Restarting script...\n");
	exec "./simbot.pl";
} else {
    &debug(3, "Terminated.\n");
	exit 0;
}
