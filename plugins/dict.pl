# SimBot Dictionary Plugin
#
# Copyright (C) 2003-04, Kevin M Stange <kevin@simguy.net>
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

package SimBot::plugin::define;

use strict;
use warnings;

# Support for the Dict protocol is found here:
use Net::Dict;

# LOOK UP: Prints a defintion to the channel.
sub look_up {
    my ($kernel, $nick, $channel, $command) = @_;
	my $line = join(' ', @_[ 4 .. $#_ ]);
	$line =~ /^\"?(.+?)\"?( in (\w+))?( (privately|publicly))?$/i;
	my $term = $1;
	my $dictionary = $3;
	my $destination = (defined $5 ? $5 : "default");

	my $dict = Net::Dict->new("pan.alephnull.com",
							  Client => SimBot::PROJECT . " " . SimBot::VERSION,
							  Timeout => 10,
							  );

	if (!defined $dict) {
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
		&SimBot::debug(3, "Received define command from " . $nick . ".\n");
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
	} else {
		&SimBot::send_message($channel, "$nick: There is no dictionary called '$dictionary' available. Try one of " . join(", ", keys(%dbs)) . ".");
	}
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "define",
						 plugin_desc => "Defines the term. Follow a term by 'in' and a dictionary name to search an alternate dictionary.",

						 event_plugin_call => \&look_up,
						 );
