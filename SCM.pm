package SCM;

use strict;
use Carp qw(carp);
use Expect;
use IO::Socket::INET;
use Data::Dumper;

sub connect{

    my $class=shift;
    my $connection_data=shift;

    print Dumper($connection_data);

    my $self=$connection_data;
    bless $self, $class;

    
    my $connect_type=$self->{'connect_type'};
    my $error;
    if ($connect_type eq 'console'){
	$error=$self->console_connect();
    }elsif($connect_type eq 'telnet'){
	$error=$self->telnet_connect();
    }elsif($connect_type eq 'ssh'){
	$error=$self->ssh_connect();
    }else{
	carp "Not support connect type: $connect_type";
	return undef;
    }
    
    if ($error){
	carp $error;
	return undef;
    }

    my $exp=$self->{'exp_obj'};
    my ($error, $prompt)=($exp->expect(15,
	[ 'Are you sure you want to continue connecting', 
			sub {	my $new_exp = shift;
	                        $new_exp->send("yes\n");
	                        exp_continue_timeout; }],
	[ qr/username:/i, sub {	my $new_exp = shift;
				$new_exp->send("$self->{'username'}\n");
	                    	exp_continue_timeout; }],
	[ qr/password:/i, sub { my $new_exp = shift;
	                        $new_exp->send("$self->{'password'}\n");
	    	                exp_continue_timeout; }],
	'#'
    ))[1,3];
    unless ($error eq ''){
        carp "Can't connect to switch, error: $error";
	return undef;
    }
    $prompt=~s/[\x0a\x0d]+/\n/g;
    my @prompt=split("\n", $prompt);
    $prompt=$prompt[$#prompt].'#';
    $self->{'prompt'}=$prompt;
    return $self;
}

sub telnet_connect {
    my $self=shift;
    
    my $telnet_cmd=$self->{'telnet_cmd'};
    my $switch_ip=$self->{'switch_ip'};
    my ($error, $port);
    ($switch_ip,$port)=split(':',$switch_ip);
    $port=23 unless ($port=~m/\d+/);
    
    return "$! $telnet_cmd" unless ( -x $telnet_cmd);

    unless ($self->socket_test($switch_ip, $port)){
        $error="$switch_ip port $port is down";
        return $error;
    }

    my $exp;

    if (! ($exp=Expect->spawn("$telnet_cmd -N $switch_ip $port"))){
        $error="can't spawn $telnet_cmd -N $switch_ip $port";
        return $error;
}

    $exp->log_stdout(0) unless ($self->{'debug_enable'});

    $self->{'exp_obj'}=$exp;

    return undef;
}

sub ssh_connect {
    my $self=shift;
    
    my $ssh_cmd=$self->{'ssh_cmd'};
    my $switch_ip=$self->{'switch_ip'};
    my $user_name=$self->{'username'};
    

    my ($error,$port);
    ($switch_ip,$port)=split(':',$switch_ip);
    $port=22 unless ($port=~m/\d+/);
    
    return "$! $ssh_cmd" unless ( -x $ssh_cmd);

    unless ($self->socket_test($switch_ip, $port)){
        $error="$switch_ip port $port is down";
        return $error;
    }

    my $exp;

    if (! ($exp=Expect->spawn("$ssh_cmd -p $port $user_name\@$switch_ip"))){
        $error="can't spawn $ssh_cmd -p $port $user_name\@$switch_ip";
        return $error;
    }

    $exp->log_stdout(0) unless ($self->{'debug_enable'});
    
    $self->{'exp_obj'}=$exp;

    return undef;
}

sub console_connect {

    my $self=shift;
    my $error;
    
    my $console_cmd=$self->{'console_cmd'};
    my $dev=$self->{'dev_name'};
    my $speed=$self->{'line_speed'};

    return "$! $console_cmd" unless (-x $console_cmd);
    return "$dev not symbol device" unless ( -c $dev);
    die "uncorrect speed: $speed" unless ($speed=~m/\d+/);

    my $basename=$console_cmd;
    $basename=~s/.*\///;

    my $exp;
    if ($basename eq 'cu'){
	if (! ($exp=Expect->spawn("$console_cmd -l $dev -s $speed"))){
	    $error="can't spawn $console_cmd -l $dev -s $speed";
	    return $error;
	}

	$exp->log_stdout(0) unless ($self->{'debug_enable'});
	    
	$error=($exp->expect(10,'Connected'))[1];
	    
	unless ($error eq ''){
		return "Can't connect to console, error: $error";
	}else{
	    $exp->send("\n");
	}
    }elsif ($basename eq 'screen'){
	if (! ($exp=Expect->spawn("$console_cmd -S scm_connect $dev $speed"))){
	    $error="can't spawn $console_cmd $dev $speed";
	    return $error;
	}

	$exp->log_stdout(0) unless ($self->{'debug_enable'});
	$exp->send("\n");
    }
    else{
	return "$console_cmd not support";
    }

    $self->{'exp_obj'}=$exp;

    return undef;
}

sub socket_test {
    my $self=shift;
    my $ip=shift;
    my $port=shift;
    if (! (my $socket=IO::Socket::INET->new(PeerAddr=> $ip, PeerPort=>"$port", Proto=>"tcp", Type=>SOCK_STREAM, Timeout=>"500"))){
    	return 0;
    }else{
	close ($socket);
	return 1;
    }
}

sub read_config{
    my $self=shift;
    
    my $exp=$self->{'exp_obj'};
    my %config;
    my $vendor='D-LINK';
    my $model;
    my $firmware;
    
    $exp->send("show config current_config\n");
    
    my $config_tmp;
    my ($error, $config)=($exp->expect(undef,
	['Next Entry', sub {	my $new_exp = shift;
				$config_tmp=$new_exp->before;
				$new_exp->send("a\n");
				exp_continue; }],
	$self->{'prompt'}
    ))[1,3];
    unless ($error eq ''){
        return "Command 'show config current_config' error: $error";
    }
    $config=$config_tmp.$config;
    $config=~s/([^\x0d])\x0a\x0d/$1/g;
    $config=~s/\x0d\x0a\x0d/\n/g;
    foreach my $line (split ("\n", $config)){
	$line=~s/^\s+//;
	$line=~s/\W+$//;
	next if ($line=~m/^(?:\*|show|$)/);
	if ($line=~m/^\#/){
	    $model=$1 if ($line=~m/^\#\s+(DES-.+?)\s+/);
	    $firmware=$1 if ($line=~m/^\#\s+Firmware:\s+Build\s+(.+?)$/);
	    next;
	}
	$config{$line}=1;
    }
    $self->{'current_switch_config'}=\%config;
    $self->{'vendor'}=$vendor;
    $self->{'model'}=$model;
    $self->{'firmware'}=$firmware;

    return undef;
}

return 1;