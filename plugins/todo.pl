# SimBot Todo List Plugin
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

package SimBot::plugin::todo;

use strict;
use warnings;

# Use the SimBot Util perl module
use SimBot::Util;

our %vers = (
	     "1.0 Beta"   =>  1,
	     "1.0 Final"  =>  1,
	     "Beyond 1.0" =>  1,
	     );

# PRINT_TODO: Prints todo list privately to the user.
sub print_todo {
    my ($kernel, $nick) = @_;
    &debug(3, "todo: Received request from " . $nick . ".\n");

    if(open(TODO, "TODO")) {
	my $version = "";
	my $todo = "";
	my $prev = "";
	foreach my $line (<TODO>) {
	    next if !defined $line;
	    chomp $line;
	    if ($line eq "======================") {
		if ($prev =~ /^Targets for (.*)/) {
		    $version = $1;
		    if (defined $vers{$version}) {
			$todo .= "For Version $version:\n";
		    }
		} else {
		    $version = $prev;
		    if (defined $vers{$version}) {
			$todo .= "$version Items:\n";
		    }
		}
	    } elsif (defined $vers{$version} && $line =~ /^- (.*)/) {
		$todo .= "- $1\n";
	    }
	    $prev = $line;
	}
	
	if ($todo ne "") {
	    chomp $todo;
	    &SimBot::send_pieces($nick, undef, $todo);
	}
    }
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "todo",
			 plugin_help => "The ever changing development todo list",
			 event_plugin_call => \&print_todo,
			 );


