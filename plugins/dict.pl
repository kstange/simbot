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

# Support for the Dict protocol is found here:
use Net::Dict;

# Server
use constant DICT_SERVER => "dict.org";

# LOOK UP: Prints a defintion to the channel.
sub look_up {
    my ($kernel, $nick, $channel, $command) = @_;
	my $line = join(' ', @_[ 4 .. $#_ ]);
	$line =~ /^\"?(.+?)\"?( (in|with) \"?(.+?)\"?)?( (privately|publicly))?$/i;
	my $dictionary;
	my $term;
	if ($1 eq "dictionaries" && $3 eq "with") {
		$dictionary = "?";
		$term = $4
	} else {
		$dictionary = $4;
		$term = $1;
	}
	my $destination = (defined $6 ? $6 : "default");

	&SimBot::debug(3, "define: Received request from " . $nick . ".\n");

	my $dict = Net::Dict->new(DICT_SERVER,
							  Client => SimBot::PROJECT . " " . SimBot::VERSION,
							  Timeout => 10,
							  );

	if (!defined $dict) {
		&SimBot::debug(1, "define: Unable to connect to " . DICT_SERVER . "dictionary server.\n");
		&SimBot::send_message($channel, "$nick: The dictionary server was unavailable.");
		return;
	}

	my %dbs = $dict->dbs();

	if (!defined $term) {
		&SimBot::send_message($channel, "$nick: Please specify which word you want defined. If you wish, you can specify 'in' and one of " . join(", ", keys(%dbs)) . ", after the word to indicate which dictionary to use.  By default, the first match in any dictionary will be used.");
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
			$definition = &SimBot::parse_style("%uline%From the $dbs{$dictionary}:%uline% $definition");

			if ((length($definition) > 440 && $destination eq "default") ||
				(length($definition) > 1320 && $destination eq "publicly")) {
				&SimBot::send_message($channel, &SimBot::parse_style("$nick: I found a definition in the $dbs{$dictionary}, but it is too long to display in the channel. Type %bold%" . $command . " \"$term\" in $dictionary privately%bold% to see it privately."));
			} elsif ($destination eq "publicly") {
				&SimBot::send_pieces($channel, "$nick:", $definition);
			} elsif ($destination eq "privately") {
				&SimBot::send_pieces($nick, undef, $definition);
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
			&SimBot::send_message($channel, "$nick: A definition for $term is available in the following dictionaries: " . join(", ", keys (%dictionaries)) . ".");
		} else {
			&SimBot::send_message($channel, "$nick: I could not find a definition for $term in any available dictionaries.");
		}

	} else {
		&SimBot::send_message($channel, "$nick: There is no dictionary called '$dictionary' available. Try one of " . join(", ", keys(%dbs)) . ".");
	}
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "define",
						 plugin_params => "[dictionaries with \"<term>\"|\"<term>\"] [in <dictionary>] [publicly|privately]",
						 plugin_help =>
qq~Defines the requested term. Quotation marks are optional unless the query has more than one word:
 %bold%dictionaries with%bold%: Lists the dictionaries with the given term
 %bold%in <dictionary>%bold%: Shows the entry from a specific dictionary, if it exists.
 %bold%publicly|privately%bold%: Specify one of these terms to request the definition in the channel or via private message.  Public messages will be limited toa reasonable length.~,
						 event_plugin_call => \&look_up,
						 );
