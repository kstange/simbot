###
#  SimBot Time Conversion Plugin
#
# DESCRIPTION:
#   The TinyURL plugin watches chat for URLs pointing to TinyURL
#   style services. When one is recognized, it looks up the URL, and
#   announces in chat where the URL points.
#
# COPYRIGHT:
#   Copyright (C) 2005, Pete Pearson
#
#   This program is free software; you can redistribute and/or modify it
#   under the terms of version 2 of the GNU General Public License as
#   published by the Free Software Foundation.
#   
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#   
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
# TODO:
#   * Allow the user to specify a time instead of only showing the current

package SimBot::plugin::time;

use warnings;
use strict;

use DateTime;
use DateTime::TimeZone;

sub do_time {
    my ($kernel, $nick, $channel, undef, @args) = @_;
    
    my $now = DateTime->now();
    my @zones;
    
    foreach my $cur_arg (@args) {
        if($cur_arg =~ m/^[\+\-]\d{4}$/)
            { push(@zones, $cur_arg); }
        if(DateTime::TimeZone->is_valid_name($cur_arg))
            { push(@zones, $cur_arg); }
    }

    if(!@zones) {
        if(my $zonelist = &SimBot::option('plugin.time', 'default_zones')) {
            @zones = split(/,/, $zonelist);
        } else {
            @zones = ('UTC');
        }
    }
    my $msg = "$nick: My clock shows "
        . $now->set_time_zone('local')->strftime('%l:%M %P %Z');
        
    foreach(@zones) {
        $msg .= ', ' . $now->set_time_zone($_)->strftime('%l:%M %P %Z');
    }
    &SimBot::send_message($channel, $msg);
}

&SimBot::plugin_register(plugin_id      => 'time',
						 plugin_params  => "[<zones>]",
                         plugin_help    =>
'Gives you the current time in a selection of time zones.
<zones>: Display these timezones. Use four digit offsets (+0400 for example) or <continent>/<city> (America/New_York) or US/<zone> (US/Eastern)',
                         event_plugin_call  => \&do_time,
                         );