# SimBot Natural Language Plugin
#
# Copyright (C) 2004-5, Kevin M Stange <kevin@simguy.net>
# Copyright (C) 2004-5, Pete Pearson
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

package SimBot::plugin::nlp;

# We'll behave, I swear!
use strict;
use warnings;

# This function is called back from IRC when it seems that someone is trying
# to address the bot.  We have a lot to do when that happens.
sub process_nlp {
    my ($kernel, $nick, $channel, $request) = @_;

	my $type;
	my $succeeded_plugin;
	my $acted = 0;

	&SimBot::debug(5, "nlp: full string: $request\n");

	# We split on these words in order to break requests up into potentially
	# several pieces.  This allows our processor to recognize more than one
	# request for the bot on a single line and deal with every one
	my @requests = split(/((,|:|!|\?|\.)|\s+(and|then|but))\s+/, $request);

	foreach my $text (@requests) {
		next if (!defined $text);

		&SimBot::debug(5, "nlp: this segment: $text\n");

		my @matches = ();
		my @still_matches = ();

		# For each plugin providing verbs, see if we can find any of these
		# verbs or alternate forms thereof in the string we're analyzing.
		# If we find none of the verbs requested by a plugin, we don't let
		# the plugin on to the next round.
		foreach my $plugin (keys (%{SimBot::hash_plugin_nlp_verbs})) {
			&SimBot::debug(5, "nlp: current plugin: $plugin\n");
			foreach my $verb (@{${SimBot::hash_plugin_nlp_verbs}{$plugin}}) {
				&SimBot::debug(5, "nlp: current verb: $verb\n");
				my $verbmatch = $verb . "|"
					. $verb . "s|"
					. $verb . "ed|"
					. $verb . "ing";
				if ($text =~ /\b($verbmatch)\b/i) {
					push(@matches, $plugin) unless (defined $matches[-1] &&
													$matches[-1] eq $plugin);
				}
			}
		}

		&SimBot::debug(5, "nlp: verbs passed for: " . join(" ", @matches) . "\n");

		# If no plugins are worthy, we'll forget about this segment of the
		# request right now and skip to the next.  If we had a plugin that
		# passed last time, but all fail this time around, we might have
		# still been talking about the same subject.  We'll try to see if
		# more of the request meets this plugin's grammar.
		next if (!@matches && !defined $succeeded_plugin);
		@matches = ($succeeded_plugin) if (!@matches);

		# Find out what type of query this is.
		# What we do here is look for typical types of request phrasings
		# to determine what type of information the user might be asking
		# for.
		if ($text =~ s/^(.*)\b(what)\s+(is|was)\b//i
			|| s/^(.*)\b(what\'s)\b//i) {
			$type = "what-is";
		}
		if ($text =~ s/^(.*)\b(who)\s+(is|was)\b//i
			|| s/^(.*)\b(who\'s)\b//i) {
			$type = "who-is";
		}
		if ($text =~ s/^(.*)\b(how)\s+(is|was)\b//i
			|| s/^(.*)\b(how\'s)\b//i) {
			$type = "how-is";
		}
		if ($text =~ s/^(.*)\b(how)\s+(is|was)\b//i
			|| s/^(.*)\b(why\'s)\b//i) {
			$type = "why-is";
		}
		if ($text =~ s/^(.*)\b(when)\s+(is|was)\b//i
			|| s/^(.*)\b(when\'s)\b//i) {
			$type = "when-is";
		}
		if ($text =~ s/^(.*)\b(where)\s+(is|was)\b//i
			|| s/^(.*)\b(where\'s)\b//i) {
			$type = "where-is";
		}
		if ($text =~ s/^(.*)\b(you)\s+(need to|have to|must|shall|will|are going to)\b//i) {
			$type = "you-must";
		}
		if ($text =~ s/^(.*)\b(you)\s+(are)\b//i) {
			$type = "you-are";
		}
		if ($text =~ s/^(.*)\b(you)\s+(should|ought to)\b//i) {
			$type = "you-should";
		}
		if ($text =~ s/^(.*)\b(you)\s+(could|can|might|may)\b//i) {
			$type = "you-may";
		}
		if ($text =~ s/^(.*)\b(what)\s+(if)\b//i) {
			$type = "what-if";
		}
		if ($text =~ s/^(.*)\b(what)\s+(do|does|can|could)\b//i) {
			$type = "what-does";
		}
		if ($text =~ s/^(.*)\b(how)\s+(do|does|can|could|should|shall|may|might)\b//i) {
			$type = "how-to";
		}
		if ($text =~ s/^(.*)\b(what|how)\s+(about)\b//i) {
			$type = "how-about";
		}
		if ($text =~ s/^(.*)\b(i|we)\s+(have|had)\b//i) {
			$type = "i-have";
		}
		if ($text =~ s/^(.*)\b(i|we)\s+(need|require)\b//i) {
			$type = "i-need";
		}
		if ($text =~ s/^(.*)\b(i|we)\s+(want|desire|request)\b//i) {
			$type = "i-want";
		}
		if ($text =~ s/^(.*)\b(would|could|will|can|might|won\'t|can\'t)\s+(you)\b//i) {
			$type = "would-you";
		}
		if ($text =~ s/^(.*)\b(do|don\'t|did|didn\'t)\s+(you)\b//i) {
			$type = "did-you";
		}
		if ($text =~ s/^(.*)\b(have|had|haven\'t|hadn\'t)\s+(you)\b//i) {
			$type = "have-you";
		}
		if ($text =~ s/^(.*)\b(shouldn\'t|should)\s+(you)\b//i) {
			$type = "should-you";
		}
		if ($text =~ s/^(.*)\b(is|isn\'t)\s+(it)\b//i) {
			$type = "is-it";
		}
		if ($text =~ s/^(.*)\b(do not|don\'t)\b//i) {
			$type = "do-not";
		}
		if ($text =~ s/^(.*)\b(should|ought)\s+(not)\b//i
			|| s/^(.*)\b(shouldn\'t|oughtn\'t)\b//i) {
			$type = "should-not";
		}
		if ($text =~ s/^(.*)\b(can|could)\s+(not)\b//i
			|| s/^(.*)\b(can\'t|couldn\'t)\b//i) {
			$type = "can-not";
		}
		if ($text =~ s/^(.*)\b(may|shall|must|will)\s+(not)\b//i
			|| s/^(.*)\b(mayn\'t|shan\'t|mustn\'t|won\'t)\b//i) {
			$type = "must-not";
		}
		# If we haven't figured out what type of query this is, and
		# we don't have previous context, we'll assume this is a command.
		if (!$type) {
			$type = "command";
		}

		&SimBot::debug(5, "nlp: query type: $type\n");

		# Now we want to eliminate any plugins that don't want queries of
		# the type we decided we have in this query.  This could be carried
		# over from a previous segment.
		foreach my $plugin (@matches) {
			foreach my $query (@{${SimBot::hash_plugin_nlp_questions}{$plugin}}) {
				if ($query eq $type) {
					push(@still_matches, $plugin)
						unless (defined $still_matches[-1] &&
								$still_matches[-1] eq $plugin);
				}
			}
		}

		@matches = @still_matches;
		@still_matches = ();
		&SimBot::debug(5, "nlp: queries passed for: " . join(" ", @matches) . "\n");

		# If we have no plugins that want the request type and verbs we've
		# found, let's get the next segment and try again.
		next if (!@matches);

		# Now, if we have "subjects" referred to, such as "dice" that we
		# would like to see in our request, we can check for those here.
		# For example, if we specify we wanted "dice" or "die", we'll
		# eliminate the plugin if one of those subjects is not referenced
		# in the given segment.  However, if the plugin doesn't have any
		# particular subjects in mind, we can just skip this part for those.
		foreach my $plugin (@matches) {
			if (!defined @{${SimBot::hash_plugin_nlp_subjects}{$plugin}}) {
				push(@still_matches, $plugin);
			}
			foreach my $subject (@{${SimBot::hash_plugin_nlp_subjects}{$plugin}}) {
				if ($text =~ /\b($subject)\b/i) {
					push(@still_matches, $plugin)
						unless (defined $still_matches[-1] &&
								$still_matches[-1] eq $plugin);
				}
			}
		}

		@matches = @still_matches;
		@still_matches = ();
		&SimBot::debug(5, "nlp: subjects passed for: " . join(" ", @matches) . "\n");

		# If no plugins' subjects matched, we'll give up here, and get the
		# next text segment and test that.
		next if (!@matches);

		# Last step!  Now we're going to look for "formats" provided by the
		# plugins that are left by this stage.  The formats are define as
		# strings that represent what kind of information the plugin needs in
		# its request.  We consider all formats optional, as long as at least
		# one matches.  We pass every single type of match we find back to
		# the plugin's call function once we've checked them all, so it can
		# decide which information is relevant or has the highest priority.

		# Convert word-form numbers into digit-based numbers:
		$text = &SimBot::numberize($text);

		foreach my $plugin (@matches) {
			my @params = ();
			foreach my $format (@{${SimBot::hash_plugin_nlp_formats}{$plugin}}) {
				my $verbmatch = "";
				foreach my $verb (@{${SimBot::hash_plugin_nlp_verbs}{$plugin}}) {
					$verbmatch .= $verb . "|"
						. $verb . "s|"
						. $verb . "ed|"
						. $verb . "ing";
				}
				$verbmatch = qr/$verbmatch/i;

				# These replacement expressions convert the slightly simpler
				# format of "formats" that we allow plugins to use into a
				# regular expression form that is easy for perl to match
				# strings with.

				# numbers
				$format =~ s/\{n\}/\\d+/g;
				# a decimal number
				$format =~ s/\{d\}/\\d+\\.?\\d*/g;
				# a quantity (a number, a decimal number, or some named values)
				$format =~ s/\{q\}/(\\d+\\.?\\d*|couple|couple of|handful of|all|every|all the|no|some|few|an|the|many|several|plenty of|lot of|lots of|copious|excessive|$verbmatch)/g;
				# x wordlike characters (a single word of length x)
				$format =~ s/\{w(\d+)\}/\\w{$1}/g;
				# one or more word-like characters ( a single word)
				$format =~ s/\{w\}/\\w+/g;
				# has (words indicating posession)
				$format =~ s/\{has\}/(with|of|having|that has|that have)/g;
				# for (words meaning belonging to)
				$format =~ s/\{for\}/(for|of)/g;
				# is (words indicating definition)
				$format =~ s/\{is\}/(is|are)/g;
				# at (words indicating location)
				$format =~ s/\{at\}/(at|in|on)/g;
				# from (words indicating source)
				$format =~ s/\{from\}/(from|of)/g;
				# to (words indicating target or destination)
				$format =~ s/\{to\}/(to|into)/g;

				&SimBot::debug(5, "nlp: using format: $format\n");

				# Push any format matches onto an array which we'll pass to
				# the plugin's function.
				if ($text =~ /\b($format)\b/i) {
					&SimBot::debug(5, "nlp: param found: $1\n");
					push(@params, $1);
				}
			}

			# Call the plugin callback function if we found any matches.
			# If the plugin returns true, note that we've acted on this
			# request, so that we can make sure to prevent the bot from
			# generating its normal chatty response.  We also note which
			# plugin has succeeded, so we can see if the next segment might
			# belong to this plugin as well.
			#
			# If this function returns false, we are going to try the next
			# plugin whose overall grammar was good enough to make it to the
			# formats level.  This allows another plugin to take this match,
			# if our first choice decide it wasn't really what it wanted.
			if (@params && &{$SimBot::event_plugin_nlp_call{$plugin}}($kernel, $nick, $channel, $plugin, @params)) {
				$acted = 1;
				$succeeded_plugin = $plugin;
				last;
			}
		}
	}
	# Once the whole string has been fully processed, we are done.  If we
	# acted, we want to return false, to tell the bot not to try to process
	# this line of chat on its own.
	return (!$acted);
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "nlp",

						 event_bot_addressed => \&process_nlp,
						 );
