# SimBot Currency Plugin
#
# Mostly taken from exchange.pl from infobot 0.45.3 and 0.49_03
# modified for SimBot by Pete Pearson
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

package SimBot::plugin::currency;
use HTTP::Request::Common qw(POST GET);
use warnings;
use constant REFERER    => 'http://www.xe.net/ucc/full.shtml';
use constant CONVERTER  => 'http://www.xe.net/ucc/convert.cgi';
use constant USERAGENT  => 'Mozilla/5.0 (Macintosh; U; PPC Mac OS X; en) AppleWebKit/124 (KHTML, like Gecko) Safari/125';
use constant CONVERSION_BY
                => 'Conversion by xe.com Universal Currency Converter(R)';

# some day I'll put a format system into simbot... some day.
#use constant FMT_NOSUCHCURRENCY
#        => 'I do not know of a currency "%currency%".';

# CONV_CURRENCY: exchanges currencies
sub conv_currency {
    my ($kernel, $nick, $channel, $command, $Amount, $From, $To) = @_;
    &SimBot::debug(3, "Received currency conversion command from $nick to convert $Amount from $From to $To\n");
    my $retval = '';

    my $ua = new LWP::UserAgent;
    $ua->agent(USERAGENT);        # Let's pretend
    $ua->timeout(10);

    # Get a list of currency abbreviations...
    my $grab = GET REFERER;
    my $reply = $ua->request($grab);
    if (!$reply->is_success) {
        &SimBot::send_message($channel,
                        "$nick: Couldn't contact XE.net."
                        . $reply->status_line);
        return;
    }
    my $html = $reply->as_string;
    my %Currencies = (grep /\S+/,
		    ($html =~ /option value=\"([^\"]+)\">.*?,\s*([^<]+)</gi)
		    );

    my %CurrLookup = reverse ($html =~ /option value=\"([^\"]+)\">([^<]+)</gi);


  if( $From =~ /^\.(\w\w)$/ ){	# Probably a tld
    $From = $tld2country{uc $1};
  }
  if( $To =~ /^\.(\w\w)$/ ){	# Probably a tld
    $To = $tld2country{uc $1};
  }

    if($#_ == 0){
        # Country lookup
        # crysflame++ for the space fix.
        $retval = '';
        foreach my $Found (grep /$From/i, keys %CurrLookup){
            $Found =~ s/,/ uses/g;
            $retval .= "$Found";
        }
        $retval=~s/\|$//;
        warn "I have no idea what this is for";
#        return substr($retval, 0, 510);
        return;
    }else{
        # Make sure that $Amount is of the form \d+(\.\d\d)?
        $Amount =~ s/[,.](\d\d)$/\01$1/;
        $Amount =~ s/[,.]//g;
        $Amount =~ s/\01/./;

        # Get the exact currency abbreviations
        my $newFrom = &GetAbb($From, %CurrLookup);
        my $newTo = &GetAbb($To, %CurrLookup);

        $From = $newFrom if $newFrom;
        $To   = $newTo   if $newTo;

        if( defined $Currencies{$From} and defined $Currencies{$To} ){

            my $req = POST CONVERTER,
                        [   timezone    => 'UTC',
                            From        => $From,
                            To          => $To,
                            Amount      => $Amount,
                        ];

            # Falsify where we came from
            $req->referer(REFERER);

            my $res = $ua->request($req);       # Submit request

            if ($res->is_success) {             # Went through ok
                my $html = $res->as_string;

                $html =~ m|</A> as of (\d{4}\.\d\d.\d\d\s\d\d:\d\d:\d\d\s\S+)|;
                $When = $1;

                $html =~ m|(\d+\.\d+) $From|;
                $Cfrom = $1;

                $html =~ m|(\d+\.\d+) $To|;
                $Cto = $1;

                if ($When) {
                    &SimBot::send_message($channel,
                        "$nick: " . CONVERSION_BY);
                    &SimBot::send_message($channel,
                        "$nick: $Cfrom ($Currencies{$From}) makes ".
                        "$Cto ($Currencies{$To})"); # ." ($When)\n";
                } else {
                    &SimBot::send_message($channel,
                        "$nick: I got some error trying that.");
                }
            } else {                                        # Oh dear.
                &SimBot::send_message($channel,
                    "$nick: I got some error trying that: "
                    . $res->status_line);
            }
        }else{
            &SimBot::send_message($channel,
			    qq($nick: I don't know about "$From" as a currency.))
                 if( ! exists $Currencies{$From} );
            &SimBot::send_message($channel,
                qq($nick: I don't know about "$To" as a currency.))
				if( ! exists $Currencies{$To} );
        }
    }
}

sub GetAbb {
    my($LookFor, %Hash) = @_;

    my $Found = (grep /$LookFor/i, keys %Hash)[0];
    $Found =~ m/\((\w\w\w)\)/;
    return $1;
}

while(<DATA>) {
    chomp;
    my ($tld, $country) = split /\s/, $_, 2;
    $tld2country{$tld} = $country;
}
close(DATA);

&SimBot::plugin_register(
						 plugin_id   => 'currency',
						 plugin_desc => 'Converts between currencies. Give it <number> <from> <to>, where from and to are countries or currency codes.',
						 modules     => 'LWP::UserAgent,HTTP::Request::Common',

						 event_plugin_call   => \&conv_currency,
						 );

__DATA__
AF	AFGHANISTAN 
AL	ALBANIA 
DZ	ALGERIA 
AS	AMERICAN SAMOA 
AD	ANDORRA 
AO	ANGOLA 
AI	ANGUILLA 
AQ	ANTARCTICA 
AG	ANTIGUA AND BARBUDA 
AR	ARGENTINA 
AM	ARMENIA 
AW	ARUBA 
AU	AUSTRALIA 
AT	AUSTRIA 
AZ	AZERBAIJAN 
BS	BAHAMAS 
BH	BAHRAIN 
BD	BANGLADESH 
BB	BARBADOS 
BY	BELARUS 
BE	BELGIUM 
BZ	BELIZE 
BJ	BENIN 
BM	BERMUDA 
BT	BHUTAN 
BO	BOLIVIA 
BA	BOSNIA AND HERZEGOWINA 
BW	BOTSWANA 
BV	BOUVET ISLAND 
BR	BRAZIL 
IO	BRITISH INDIAN OCEAN TERRITORY 
BN	BRUNEI DARUSSALAM 
BG	BULGARIA 
BF	BURKINA FASO 
BI	BURUNDI 
KH	CAMBODIA 
CM	CAMEROON 
CA	CANADA 
CV	CAPE VERDE 
KY	CAYMAN ISLANDS 
CF	CENTRAL AFRICAN REPUBLIC 
TD	CHAD 
CL	CHILE 
CN	CHINA 
CX	CHRISTMAS ISLAND 
CC	COCOS (KEELING) ISLANDS 
CO	COLOMBIA 
KM	COMOROS 
CG	CONGO 
CD	CONGO	THE DEMOCRATIC REPUBLIC OF THE 
CK	COOK ISLANDS 
CR	COSTA RICA 
CI	COTE D'IVOIRE 
HR	CROATIA (local name: Hrvatska) 
CU	CUBA 
CY	CYPRUS 
CZ	CZECH REPUBLIC 
DK	DENMARK 
DJ	DJIBOUTI 
DM	DOMINICA 
DO	DOMINICAN REPUBLIC 
TP	EAST TIMOR 
EC	ECUADOR 
EG	EGYPT 
SV	EL SALVADOR 
GQ	EQUATORIAL GUINEA 
ER	ERITREA 
EE	ESTONIA 
ET	ETHIOPIA 
FK	FALKLAND ISLANDS (MALVINAS) 
FO	FAROE ISLANDS 
FJ	FIJI 
FI	FINLAND 
FR	FRANCE 
FX	FRANCE	METROPOLITAN 
GF	FRENCH GUIANA 
PF	FRENCH POLYNESIA 
TF	FRENCH SOUTHERN TERRITORIES 
GA	GABON 
GM	GAMBIA 
GE	GEORGIA 
DE	GERMANY 
GH	GHANA 
GI	GIBRALTAR 
GR	GREECE 
GL	GREENLAND 
GD	GRENADA 
GP	GUADELOUPE 
GU	GUAM 
GT	GUATEMALA 
GN	GUINEA 
GW	GUINEA-BISSAU 
GY	GUYANA 
HT	HAITI 
HM	HEARD AND MC DONALD ISLANDS 
VA	HOLY SEE (VATICAN CITY STATE) 
HN	HONDURAS 
HK	HONG KONG 
HU	HUNGARY 
IS	ICELAND 
IN	INDIA 
ID	INDONESIA 
IR	IRAN (ISLAMIC REPUBLIC OF) 
IQ	IRAQ 
IE	IRELAND 
IL	ISRAEL 
IT	ITALY 
JM	JAMAICA 
JP	JAPAN 
JO	JORDAN 
KZ	KAZAKHSTAN 
KE	KENYA 
KI	KIRIBATI 
KP	KOREA	DEMOCRATIC PEOPLE'S REPUBLIC OF 
KR	KOREA	REPUBLIC OF 
KW	KUWAIT 
KG	KYRGYZSTAN 
LA	LAO PEOPLE'S DEMOCRATIC REPUBLIC 
LV	LATVIA 
LB	LEBANON 
LS	LESOTHO 
LR	LIBERIA 
LY	LIBYAN ARAB JAMAHIRIYA 
LI	LIECHTENSTEIN 
LT	LITHUANIA 
LU	LUXEMBOURG 
MO	MACAU 
MK	MACEDONIA	THE FORMER YUGOSLAV REPUBLIC OF 
MG	MADAGASCAR 
MW	MALAWI 
MY	MALAYSIA 
MV	MALDIVES 
ML	MALI 
MT	MALTA 
MH	MARSHALL ISLANDS 
MQ	MARTINIQUE 
MR	MAURITANIA 
MU	MAURITIUS 
YT	MAYOTTE 
MX	MEXICO 
FM	MICRONESIA	FEDERATED STATES OF 
MD	MOLDOVA	REPUBLIC OF 
MC	MONACO 
MN	MONGOLIA 
MS	MONTSERRAT 
MA	MOROCCO 
MZ	MOZAMBIQUE 
MM	MYANMAR 
NA	NAMIBIA 
NR	NAURU 
NP	NEPAL 
NL	NETHERLANDS 
AN	NETHERLANDS ANTILLES 
NC	NEW CALEDONIA 
NZ	NEW ZEALAND 
NI	NICARAGUA 
NE	NIGER 
NG	NIGERIA 
NU	NIUE 
NF	NORFOLK ISLAND 
MP	NORTHERN MARIANA ISLANDS 
NO	NORWAY 
OM	OMAN 
PK	PAKISTAN 
PW	PALAU 
PA	PANAMA 
PG	PAPUA NEW GUINEA 
PY	PARAGUAY 
PE	PERU 
PH	PHILIPPINES 
PN	PITCAIRN 
PL	POLAND 
PT	PORTUGAL 
PR	PUERTO RICO 
QA	QATAR 
RE	REUNION 
RO	ROMANIA 
RU	RUSSIAN FEDERATION 
RW	RWANDA 
KN	SAINT KITTS AND NEVIS 
LC	SAINT LUCIA 
VC	SAINT VINCENT AND THE GRENADINES 
WS	SAMOA 
SM	SAN MARINO 
ST	SAO TOME AND PRINCIPE 
SA	SAUDI ARABIA 
SN	SENEGAL 
SC	SEYCHELLES 
SL	SIERRA LEONE 
SG	SINGAPORE 
SK	SLOVAKIA (Slovak Republic) 
SI	SLOVENIA 
SB	SOLOMON ISLANDS 
SO	SOMALIA 
ZA	SOUTH AFRICA 
GS	SOUTH GEORGIA AND THE SOUTH SANDWICH ISLANDS 
ES	SPAIN 
LK	SRI LANKA 
SH	ST. HELENA 
PM	ST. PIERRE AND MIQUELON 
SD	SUDAN 
SR	SURINAME 
SJ	SVALBARD AND JAN MAYEN ISLANDS 
SZ	SWAZILAND 
SE	SWEDEN 
CH	SWITZERLAND 
SY	SYRIAN ARAB REPUBLIC 
TW	TAIWAN	PROVINCE OF CHINA 
TJ	TAJIKISTAN 
TZ	TANZANIA	UNITED REPUBLIC OF 
TH	THAILAND 
TG	TOGO 
TK	TOKELAU 
TO	TONGA 
TT	TRINIDAD AND TOBAGO 
TN	TUNISIA 
TR	TURKEY 
TM	TURKMENISTAN 
TC	TURKS AND CAICOS ISLANDS 
TV	TUVALU 
UG	UGANDA 
UA	UKRAINE 
AE	UNITED ARAB EMIRATES 
GB	UNITED KINGDOM 
US	UNITED STATES 
UM	UNITED STATES MINOR OUTLYING ISLANDS 
UY	URUGUAY 
UZ	UZBEKISTAN 
VU	VANUATU 
VE	VENEZUELA 
VN	VIET NAM 
VG	VIRGIN ISLANDS (BRITISH) 
VI	VIRGIN ISLANDS (U.S.) 
WF	WALLIS AND FUTUNA ISLANDS 
EH	WESTERN SAHARA 
YE	YEMEN 
YU	YUGOSLAVIA 
ZM	ZAMBIA 
ZW	ZIMBABWE
