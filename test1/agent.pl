#!/usr/bin/perl

use IO::Socket;
use Net::hostent;

die "usage $0 <port number>\n" unless @ARGV == 1;
die "usage $0 <port number>\n" unless $ARGV[0] =~ /\d+/;
$PORT=$&;
die "port number should be from 8000 to 9000" if $PORT < 8000;
die "port number should be from 8000 to 9000" if $PORT > 9000;

my %watchPorts = ();
my %activePorts = ();

my %port_to_pid = ();

$server = IO::Socket::INET->new(
        Proto => "tcp",
        LocalPort => $PORT,
        Listen => SOMAXCONN,
        Reuse => 1
);

die "can't setup server" unless $server;
print "[Server $0 accepting clients]\n";

while ($client = $server->accept()) {
    my $flag = 0;
    $client->autoflash(1);
    $hostinfo = gethostbyaddr($client->peeraddr);
    printf "[Connect from %s]\n", $hostinfo ? $hostinfo->name : $client->peerhost;
    while ( <$client> ) {
        my $flagA = 0;
        next unless /\S+/; # blank line;
        if (/quit|exit/i) { $flagA = 1; }
        elsif (/stop/i) { $flag = 1; $flagA = 1; }
        elsif (/watch_ports/i) { &watch_ports(); }
        elsif (/date|time/i) { printf $client "%s\n", scalar localtime(); }
        elsif (/see_ports/i) { &see_ports(); }
        elsif (/check_ports/i) { &check_ports(); }
        elsif (/check_ram/i) { &check_ram(); }
        print $client ".\n";
        last if $flagA;
    }
    close $client;
    last if $flag;
}

sub watch_ports {
    print "watch_ports\n";
    while ( <$client> ) {
        last if $_ =~ /^\./;
        $watchPorts{$1} = 0 if $_ =~ /(\d+)/;
        print $_;
    }
}

sub see_ports {
    print "see_ports\n";
    foreach my $port (sort {$a <=> $b} keys %watchPorts) {
        print $client $port.'='.$watchPorts{$port}."\n";
        print $port.'='.$watchPorts{$port}."\n";
    }
}

sub check_ports {
    print "check_ports\n";
    %activePorts = ();
    my $flag = 0;
    foreach my $port (`netstat -ln | egrep 'udp|tcp' | grep LISTEN | awk '{print \$4}' | awk -F: '{print \$2}' | sort -n`) {
        next unless $port =~ /\d+/;
        $activePorts{$&} = 1;
    }
    foreach my $port (keys %watchPorts) {
        if ($watchPorts{$port}) {
            next if exists $activePorts{$port};
            $watchPorts{$port} = 0;
            print "watchPorts{$port} = 0\n";
            $flag = 1;
        } else {
            next if exists $activePorts{$port};
            $watchPorts{$port} = 1;
            print "watchPorts{$port} = 1\n";
            $flag = 1;
        }
    }
    print $client "$flag\n";
}

sub check_ram {
    my @buff = ();
    print "check_ram\n";
    &look_for_pid();
    while ( <$client> ) {
        last if $_ =~ /^\./;
        next unless $_ =~ /(\d+)/;
        my $port = $1;
        if (exists $port_to_pid{$port}) {
            my $pid = $port_to_pid{$port};
            my ($used, $mem, $ccGC) = &get_gc_info($pid);
            my $occ = sprintf("%.1f", $used / $mem * 100);
            push @buff, "port=$port pid=$pid used=$used mem=$mem occ=$occ ccGC=$ccGC\n";
        } else {
            push @buff, "unknown port\n";
        }
    }
    print $client @buff;
}

sub get_gc_info {
    my $pid = shift;
    my %hash = &parse_jstat('gc', $pid);
    return () if keys %hash eq 0;
    my $mem = sprintf('%d', $hash{'S0C'} + $hash{'S1C'} + $hash{'EC'} + $hash{'OC'} + $hash{'PC'});
    my $used = sprintf('%d', $hash{'S0U'} + $hash{'S1U'} + $hash{'EU'} + $hash{'OU'} + $hash{'PU'});
    my $ccGC = $hash{'ccgc'};
    return ($used, $mem, $ccGC);
}

sub parse_jstat {
    my ($option, $pid) = @_;
    my %hash = ();
    my @buff = `/sbcimp/run/tp/sun/jdk/v1.6.0_10/bin/jstat -$option $pid 0 1 2>/dev/null`;
    return %hash unless @buff == 2;
    my @title = $buff[0] =~ /\S+/g;
    my @value = $buff[1] =~ /\S+/g;
    for (my $i = 0; $i <= $#title; $i++) {
        $hash{$title[$i]} = $i;
    }
    foreach my $key (keys %hash) {
        $hash{$key} = $value[$hash{$key}];
    }
    my $ccGC = 0;
    $ccGC = 1 if $buff[1] =~ /-XX:+UseConcMarkSweepGC/;
    $hash{'ccgc'} = $ccGC;
    return %hash
}

sub look_for_pid {
    %port_to_pid = ();
    my @buff = `netstat -lnp --tcp 2>/dev/null | grep java | awk 'print \$4 " " \$7' | awk -F: '{print \$2}' | sort -n`;
    foreach my $line (@buff) {
        next unless $line =~ /(\d+) (\d+)\/java/;
        my $port = $1;
        my $pid = $2;
        $port_to_pid{$port} = $pid;
    }
}

