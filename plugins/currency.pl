###
#  SimBot Currency Plugin
#
# DESCRIPTION:
#   Provides SimBot the ability to convert currencies. Responds to %currency
#   <value> <from> <to>.
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
#   * Handle unknown countries gracefully
#   * Handle countries whose names are multiple words ("Hong Kong")
#     (ok, not a country, whatever)
#   * perhaps add a TLD to country name mapping so those abbreviations could
#     be used?

package SimBot::plugin::currency;

use warnings;
use strict;

use constant WSDL_FILE_LOCATION 
    => 'http://www.xmethods.net/sd/2001/CurrencyExchangeService.wsdl';
    
    
use SOAP::Lite;
use vars qw( $SOAP );

sub messup_currency {
    $SOAP = new SOAP::Lite
        -> service(WSDL_FILE_LOCATION)
    or die "Could not set up SOAP::Lite";
}

sub get_currency {
    my ($kernel, $nick, $channel, $self, $orig_amount, $from_currency, $to_currency) = @_;
    
    # first, let's get the exchange rate
    my $rate;
    if($rate = $SOAP->getRate($from_currency, $to_currency)) {
        &SimBot::send_message($channel, "$nick: $orig_amount $from_currency is "
            . $orig_amount * $rate . " $to_currency");
    } else {
        &SimBot::send_message($channel, "$nick: Sorry, something went wrong. Try using a country name instead of a currency name.");
    }
}

&SimBot::plugin_register(plugin_id      => 'currency',
						 plugin_params  => "<amount> <from country> <to country>",
                         plugin_help    =>
'%bold%<amount>%bold% is the amount of currency to exchange
%bold%<from country>%bold% and %bold%<to country>%bold% are the %uline%countries%uline% to exchange currency between',
                         event_plugin_call  => \&get_currency,
                         event_plugin_load  => \&messup_currency,
                         
                         );
