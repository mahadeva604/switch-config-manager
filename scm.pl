#!/usr/bin/perl

use strict;
use Expect;
use NewIOFile;
use IO::Socket::INET;
use Config::Tiny;
use Data::Dumper;

my $global_config = Config::Tiny->new;
$global_config = Config::Tiny->read('scm.conf');
my $telnet_cmd=$global_config->{'path'}->{'telnet'};
my $ssh_cmd=$global_config->{'path'}->{'ssh'};
my $console_cmd=$global_config->{'path'}->{'console'};

my $logging_flag=$global_config->{'log'}->{'enable'};
my $debug_flag=$global_config->{'log'}->{'debug'};
my $log_file=$global_config->{'log'}->{'log_file'};

my $fh_log;
$fh_log = NewIOFile->new(">> $log_file") or die $! if ($logging_flag);

print Dumper(&console_connect("/tmp"));

sub telnet_connect {

    my $switch_ip=shift;
    my ($error,$port);
	($switch_ip,$port)=split(':',$switch_ip);
    $port=23 if ($port eq '');
    
    die $! unless ( -x $telnet_cmd);
    
	unless (&socket_test($switch_ip, $port)){                   
        $error="$switch_ip port $port is down";
        die $error;                                             
    }

	my $exp;
   
    if (! ($exp=Expect->spawn("$telnet_cmd -N $switch_ip $port"))){
        $error="can't spawn $telnet_cmd -N $switch_ip $port";
        die $error;
    }
	
	$exp->log_stdout(0);

#    if ($logging_flag && $debug_flag){
#        $exp->log_file($fh_log);
#    }else{
#	$exp->log_stdout(0);
#    }

    return $exp;
}

sub ssh_connect {

    my $switch_ip=shift;
	my $user_name=shift;
	my $password=shift;
    my ($error,$port);
	($switch_ip,$port)=split(':',$switch_ip);
    $port=22 if ($port eq '');
    
    die $! unless ( -x $ssh_cmd);
    
    unless (&socket_test($switch_ip, $port)){
        $error="$switch_ip port $port is down";
        die $error;
    }
    
    my $exp;
    
    if (! ($exp=Expect->spawn("$ssh_cmd -p $port $user_name\@$switch_ip"))){
        $error="can't spawn $ssh_cmd -p $port $user_name\@$switch_ip";
        die $error;
    }
	my $patidx=($exp->expect(10,"assword:","Are you sure you want to continue connecting"))[0];
	if ($patidx==2){
		$exp->send("yes\n");
		my $patidx=$exp->expect(10,"assword:");
	}
	$exp->send($password);

	$exp->log_stdout(0);

#    if ($logging_flag && $debug_flag){
#        $exp->log_file($fh_log);
#    }else{
#	$exp->log_stdout(0);
#    }

    return $exp;
}


sub console_connect {

    my $dev=shift;
    my $speed=shift;
	my $error;
    
    die $! unless ( -x $console_cmd);
	die "$dev not symbol device" unless ( -c $dev);
	die "uncorrect speed: $speed" unless ($speed=~m/\d+/);
	

    my $basename=$console_cmd;
	$basename=~s/.*\///;

	my $exp;
	if ($basename eq 'cu'){
   
	    if (! ($exp=Expect->spawn("$console_cmd -l $dev -s $speed"))){
	        $error="can't spawn $console_cmd -l $dev -s $speed";
	        die $error;
	    }
		
		$exp->log_stdout(0);

#    if ($logging_flag && $debug_flag){
#        $exp->log_file($fh_log);
#    }else{
#	$exp->log_stdout(0);
#    }
	}else{
		die "$console_cmd not support";
	}
    return $exp;
}

sub socket_test {
	my $ip=shift;
	my $port=shift;
    if (! (my $socket=IO::Socket::INET->new(PeerAddr=> $ip, PeerPort=>"$port", Proto=>"tcp", Type=>SOCK_STREAM, Timeout=>"500"))){	
    	return 0;
	}else{
		close ($socket);
		return 1;
    }
}
