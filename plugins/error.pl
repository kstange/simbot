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

sub random_error {
    my ($kernel, $nick, $channel) = @_;
    open(FILE, "errors.db");
    my @lines = <FILE>;
    close(FILE);
    my $error = &SimBot::pick(@lines);
    chomp($error);
    $error =~ s/\$nick/$nick/g;
    $kernel->post(bot => privmsg => $channel, $error);
}

# Register Plugin
SimBot::plugin_register(plugin_id   => "error",
			plugin_desc => "Prints out a random error message.",
			modules     => "",

			event_plugin_call => "random_error",
			);
