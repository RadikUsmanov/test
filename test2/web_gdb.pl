#!/usr/bin/perl -w
use strict;
use warnings;

use IPC::Open3;
use Fcntl qw(F_SETFL F_GETFL O_NONBLOCK);

use CGI;
use JSON;
use HTTP::Daemon;
use HTTP::Headers;
use HTTP::Status;
use Encode;
use Data::Dumper;

my $d = HTTP::Daemon->new(LocalAddr => 'localhost', LocalPort => 8080) or die "Can't launch HTTP daemon: $!";
print "Please contact me at: <URL:", $d->url, ">\n";

local(*HIS_IN, *HIS_OUT, *HIS_ERR);
my $pid = open3(*HIS_IN, *HIS_OUT, *HIS_ERR, 'gdb --quiet') or die "Can't launch gdb: $!";

my $flags = fcntl (HIS_OUT, F_GETFL, 0) or die "Can't get flags: $!";
fcntl (HIS_OUT, F_SETFL, $flags|O_NONBLOCK) or die "Can't set O_NONBLOCK: $!";

$flags = fcntl (HIS_ERR, F_GETFL, 0) or die "Can't get flags: $!";
fcntl (HIS_ERR, F_SETFL, $flags|O_NONBLOCK) or die "Can't set O_NONBLOCK: $!";

&wait_prompt(); # Skip introduction from GDB
&command('set confirm off');
&command('set listsize 20');
&command('set height 0');
&command('set width unlimited');
my $finish;

while (my ($c) = $d->accept) {
    $c->autoflush(1);
    my $r = $c->get_request;
    if ($r) {
        my $h = HTTP::Headers->new;
        my $resp = HTTP::Response->new( 200 );
        $h->content_type('application/json');
        $resp->content( &treat_request($r) );
        $resp->header(
            'Content-Type' => 'application/json',
            'Access-Control-Allow-Origin' => '*'
        );
        $c->send_response($resp);
    }
    $c->close;
    undef($c);
    last if $finish;
}
&command('quit');

waitpid $pid, 0;
exit 0;

sub treat_request {
    my $r = shift;
    
    my $query_params = CGI->new($r->url->query)->Vars;
    return '[]' unless exists $query_params->{cmd};
    my $cmd = $query_params->{cmd};
    my $resp = {};
    if ($cmd eq 'break')    { $resp = &cmd_arg($cmd, $query_params->{point}); } # setup breakpoint
    if ($cmd eq 'info')     { $resp = &cmd_info($cmd, $query_params); }
    if ($cmd eq 'list')     { $resp = &cmd_list($cmd, $query_params); }
    if ($cmd eq 'file')     { $resp = &cmd_arg($cmd, $query_params->{filename}); } # load program
    if ($cmd eq 'clear')    { $resp = &cmd_arg($cmd, $query_params->{point}); } # delete breakpoint
    if ($cmd eq 'delete')   { $resp = &cmd($cmd); } # delete all breakpoints
    if ($cmd eq 'run')      { $resp = &cmd($cmd); } # launch program
    if ($cmd eq 'frame')    { $resp = &cmd($cmd); } # current position in C/C++ source
    if ($cmd eq 'continue') { $resp = &cmd($cmd); } # continue execution
    if ($cmd eq 'step')     { $resp = &cmd($cmd); } # make one step more
    if ($cmd eq 'next')     { $resp = &cmd($cmd); } # make step over
    
    if ($cmd eq 'quit')     { $finish = 1; }
    return encode_json($resp);
}

sub cmd {
    my $cmd = shift;

    my $res = {};
    $res->{respond} = [];
    $res->{cmd} = $cmd;

    my $res1 = &command($cmd);
    push @{$res->{respond}}, $res1;

    return $res;
}

sub cmd_arg {
    my ($cmd, $arg) = @_;

    my $res = {};
    $res->{respond} = [];
    $res->{cmd} = $cmd;

    my $res1 = &command("$cmd $arg");
    push @{$res->{respond}}, $res1;
    return $res   
}

sub cmd_list {
    my ($cmd, $query_params) = @_;
    my $arg = $query_params->{arg};
    $cmd .= " $arg" if $arg;
    my $res1 = &command($cmd);
    return {} unless exists $res1->{resp}{out};
    my $code = [];
    my $first_id;
    my $last_id;
    for (@{$res1->{resp}{out}}) {
        next unless $_ =~ /^\d+/;
        my $id = $&;
        my $line = $';
        $first_id = $id if !$first_id or $id < $first_id;
        $last_id = $id if !$last_id or $id > $last_id;
        push @$code, {id => $id, line => $line};
    }
    my $resp = $res1->{resp};
    $resp->{code} = $code if @$code > 0;
    $resp->{first_id} = $first_id if $first_id;
    $resp->{last_id} = $last_id if $last_id;

    my $prev_id;
    if ($first_id < 21) {
        $prev_id = 1;
    } elsif (($first_id - 1) % 20) {
        $prev_id = $first_id - ($first_id - 1) % 20; 
    } else {
        $prev_id = $first_id - 20; 
    }
    
    my $next_id = $first_id - ($first_id - 1) % 20 + 20;
    
    $resp->{prev_id} = $prev_id;
    $resp->{next_id} = $next_id;
    my $res = {};
    $res->{respond} = [];
    $res->{cmd} = $cmd;
    push @{$res->{respond}}, $res1;
    return $res;
}

sub cmd_info {
    my ($cmd, $query_params) = @_;
    my $arg = $query_params->{arg};
    $cmd .= " $arg" if $arg;
    my $res1 = &command($cmd);
    return {} unless exists $res1->{resp}{out};
   
    if($arg eq 'breakpoints') {
        my $ptr = $res1->{resp}{out};
        if ($ptr->[0] =~ /No breakpoints or watchpoints/) {
            $res1->{resp}{out} = [];
        } else {
            for (@{$res1->{resp}{out}}) {
                my $line = $_;
                $_ = { 'line' => $line };
                $_->{'addr'} = $1 if $line =~ /(\S+\:\d+)\s*$/;
            }
        }
    }
    
    my $res = {};
    $res->{respond} = [];
    $res->{cmd} = $cmd;
    push @{$res->{respond}}, $res1;
    return $res;
}

# Function command($cmd)
#       Send requested command to debugger, read feedback
# Parameters
#       $cmd - command for the GDB utility
# Return
#       zero or more lines in feedback except the (gdb) prompt
sub command {
    my $cmd = shift;

    &send_cmd($cmd);
    return {} if $cmd eq 'quit';  
   
    my $obj = { 'out' => [], 'err' => [], 'cmd' => $cmd };
    &wait_prompt($obj);
    return &make_report($obj);
}

sub make_report {
    my $obj = shift;

    my $report = {};
    $report->{'req'} = $obj->{cmd};
    if (@{$obj->{out}} > 0) {
        $report->{'resp'}->{'out'} = [] unless exists $report->{'resp'}->{'out'};
        push @{$report->{'resp'}->{'out'}}, map {decode("UTF-8", $_)} @{$obj->{out}};
    }
    if (@{$obj->{err}} > 0) {
        $report->{'resp'}->{'err'} = [] unless exists $report->{'resp'}->{'err'};
        push @{$report->{'resp'}->{'err'}}, map {decode("UTF-8", $_)} @{$obj->{err}};
    }

    return $report;
}

sub send_cmd {
    my $cmd = shift;
    print HIS_IN "$cmd\n";
    print "\$ $cmd\n";
}

# Function wait_prompt()
#       Wait feedback from the gdb programm
sub wait_prompt {
    my $obj = shift;
    until (&get_output($obj)) {;}
}

# Function get_output($obj)
#       Wait feedback from the gdb programm
# Return
#       1 - got feedback
#       0 - still waiting
sub get_output {
    my $obj = shift;
    my $finish = 0;
    my $flag;

    do {
        my ($out, $err);
        $flag = 0;

        if (defined ($out = <HIS_OUT>)) {
            if ($out =~ /^\(gdb\)/) {
                $finish = 1;
            } else {
                push @{$obj->{out}}, $out;
                $flag = 1;
                print $out;
            }
        }
        if (defined ($err = <HIS_ERR>)) {
            push @{$obj->{err}}, $err;
            print $err;
        }
    } while ($flag);

    return $finish;
}

# http://127.0.0.1:8080/?cmd=load_file&filename=testA
