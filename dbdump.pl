#!/usr/bin/perl -w

$file = $ARGV[0];

dbmopen(%db, $file, 0665) || die $!;

while(($key, $val) = each %db) {
    print "$key => $val\n";
}

dbmclose(%db);
