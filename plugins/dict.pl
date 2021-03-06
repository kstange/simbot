# SimBot Dictionary Plugin
#
# Copyright (C) 2003-05, Kevin M Stange <kevin@simguy.net>
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

# TODO: allow the user to fetch individual definitions for a given word

package SimBot::plugin::define;

use strict;
use warnings;

# Use the SimBot Util perl module
use SimBot::Util;

# Support for the Dict protocol is found here:
use Net::Dict;

# Server
use constant DICT_SERVER => "dict.org";

# LOOK UP: Prints a defintion to the channel.
sub look_up {
    my ($kernel, $nick, $channel, $command) = @_;
	my $line = join(' ', @_[ 4 .. $#_ ]);
	my ($dictionary, $term, $destination);
	if ($line =~ /^\"?(.+?)\"?( (in|with) \"?(.+?)\"?)?( (privately|publicly))?$/i) {
		if ($1 eq "dictionaries" && $3 eq "with") {
			$dictionary = "?";
			$term = $4;
		} else {
			$dictionary = $4;
			$term = $1;
		}
		$destination = (defined $6 ? $6 : "default");
	}

	&debug(3, "define: Received request from " . $nick . ".\n");

	my $dict = Net::Dict->new(DICT_SERVER,
							  Client => PROJECT . " " . VERSION,
							  Timeout => 10,
							  );

	if (!defined $dict) {
		&debug(1, "define: Unable to connect to " . DICT_SERVER . "dictionary server.\n");
		&SimBot::send_message($channel, "$nick: The dictionary server was unavailable.");
		return;
	}

	my %dbs = $dict->dbs();
	# We're killing these because they're "pseudo-dictionary" names and
	# they don't actually work right.  They won't return results anyway.
	delete $dbs{"--exit--"} if defined $dbs{"--exit--"};
	delete $dbs{"all"}      if defined $dbs{"all"};
	delete $dbs{"trans"}    if defined $dbs{"trans"};
	delete $dbs{"english"}  if defined $dbs{"english"};


	if (!defined $term) {
		&SimBot::send_message($channel, "$nick: Please specify which word you want defined.  You can specify 'in <dictionary>' after the word to search a specific dictionary from the list I am messaging you now.  If you don't specify, I'll just look for the first match.");
		&SimBot::send_pieces_with_notice($nick, undef, "Available Dictionaries: " . join(", ", keys(%dbs)) . ".");
		return;
	}

	my $found = 0;
	if (defined $dictionary) {
		foreach (keys(%dbs)) {
			if ($_ eq $dictionary) {
				$found = 1;
				last;
			}
		}
	}

	if(!defined $dictionary || $found) {
		my $def;

		if (defined $dictionary) {
			$def = $dict->define($term, ($dictionary));
		} else {
			$def = $dict->define($term);
		}

		if (@{$def} != 0) {
			my $definition = ${${$def}[0]}[1];
			$dictionary = ${${$def}[0]}[0];
			$definition =~ s/\s+/ /g;
			$definition = &parse_style("%uline%From the $dbs{$dictionary}:%uline% $definition");

			if ((length($definition) > 440 && $destination eq "default") ||
				(length($definition) > 1320 && $destination eq "publicly")) {
				&SimBot::send_message($channel, &parse_style("$nick: I found a definition in the $dbs{$dictionary}, but it is too long to display in the channel. Type %bold%" . $command . " \"$term\" in $dictionary privately%bold% to see it privately."));
			} elsif ($destination eq "publicly") {
				&SimBot::send_pieces($channel, "$nick:", $definition);
			} elsif ($destination eq "privately") {
				&SimBot::send_pieces_with_notice($nick, undef, $definition);
			} else {
				&SimBot::send_message($channel, "$nick: $definition");
			}
		} else {
			&SimBot::send_message($channel, "$nick: I could not find a definition for $term in " . (defined $dictionary ? "the $dbs{$dictionary}" : "any available dictionaries") . ".");
		}
	} elsif (defined $dictionary && $dictionary eq "?") {
		my $def = $dict->define($term);

		if (@{$def} != 0) {
			my %dictionaries = ();
			foreach my $entry (@{$def}) {
				if (!defined $dictionaries{${$entry}[0]}) {
					$dictionaries{${$entry}[0]} = 1;
				} else {
					$dictionaries{${$entry}[0]}++;
				}
			}
			&SimBot::send_pieces($channel, "$nick:", "A definition for $term is available in the following dictionaries: " . join(", ", keys (%dictionaries)) . ".");
		} else {
			&SimBot::send_message($channel, "$nick: I could not find a definition for $term in any available dictionaries.");
		}

	} else {
		&SimBot::send_message($channel, &parse_style("$nick: There is no dictionary called '$dictionary' available. Type %bold%$command%bold% with no parameters to see a list of dictionaries you can use."));
	}
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "define",
						 plugin_params => "[dictionaries with \"<term>\"|\"<term>\" [in <dictionary>]] [publicly|privately]",
						 plugin_help =>
qq~Defines the requested term. Quotation marks are optional unless the query has more than one word.  To see a list of available dictionaries privately, simply use the define command with no parameters.
%bold%dictionaries with%bold%: Lists the dictionaries with the given term.
%bold%in <dictionary>%bold%: Shows the entry from a specific dictionary, if it exists.
%bold%publicly%bold% or %bold%privately%bold%: Specify one of these terms to request the definition in the channel or via private message. Public messages will be limited to a reasonable length.~,
						 event_plugin_call => \&look_up,
						 );
