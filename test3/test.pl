#!/usr/bin/perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::HTTP;
use Time::Moment;

# Read URLs from stdin. Start treatment as soon as meet EOF.
my @urls = <>;

my $cv = AnyEvent->condvar();
my $count = 0; # Counter of treated URLs

my %stat; # Stat table
for my $url (@urls) {
    $url =~ s/\s$//g;
    $stat{$url} = { url => $url };
}

for my $url (@urls) {
     $stat{$url}{start} = Time::Moment->now;
     http_get(
        $url, sub {
            my ($content, $headers) = @_;
            $stat{$url}{stop} = Time::Moment->now;

            # Send content to stdout. 
            # Suppose there are request for text only (HTML, JavsScript, CSS), but not binary (images, Java classes, etc.)
            print $content; 

            $count++;
            $cv->send if $count == scalar @urls; # All URLs are treated. Unlock stat report
        },
    );
}

$cv->recv(); # Lock until all URLs are treated

print "\n" . '=' x 30 . ' Stat ' . '=' x 30 . "\n";
for my $url (keys %stat) {
    my $delay = $stat{$url}{start}->delta_milliseconds($stat{$url}{stop});
    print "$url\t\tdelay = $delay milliseconds\n";
}
