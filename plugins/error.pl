# SimBot Error Plugin
#
# Copyright (C) 2003, Kevin M Stange <kevin@simguy.net>
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

package SimBot::plugin::error;

use strict;
use warnings;

sub random_error {
    my ($kernel, $nick, $channel) = @_;
    &SimBot::debug(3, "error: Got error request from " . $nick . ".\n");
    open(FILE, "errors.db");
    my @lines = <FILE>;
    close(FILE);
    my $error = &SimBot::pick(@lines);
    chomp($error);
    $error =~ s/\$nick/$nick/g;
    &SimBot::send_message($channel, $error);
}

sub random_quip {
    my ($nick, $channel) = @_[1,2];
    &SimBot::debug(3, "error: Got list request from " . $nick . ".\n");
    my @reply = (
				 "$nick: HER R TEH FIL3Z!!!! TEH PR1Z3 FOR U! KTHXBYE",
				 "$nick: U R L33T H4X0R!",
				 "$nick: No files for you!",
				 "$nick: Sorry, I have reached my piracy quota for this century.  Please return in " . (100 - ((localtime(time))[5] % 100)) . " years.",
				 "$nick: The FBI thanks you for your patronage.",
				 "$nick: h4x0r5 0n teh yu0r pC? oh nos!!! my megahurtz haev been stoeled!!!!!111 safely check yuor megahurtz with me, free!",
				 "$nick: Ur Leet-Foo is weak!",
				 );
    &SimBot::send_message($channel, &SimBot::pick(@reply));
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "error",
						 plugin_desc => "Prints out a random error message.",

						 event_plugin_call => \&random_error,
						 );

&SimBot::plugin_register(plugin_id   => "list",

						 event_plugin_call => \&random_quip,
						 );
