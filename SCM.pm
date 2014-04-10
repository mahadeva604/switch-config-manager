package SCM;

use strict;
use Carp qw(carp);
use Expect;
use IO::Socket::INET;
use Storable qw(dclone);

use constant TAGGED_PORT => 0;
use constant UNTAGGED_PORT => 1;
use constant DELETE_PORT => 2;

sub connect{

    my $class=shift;
    my $connection_data=shift;

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
	return (1, undef);
    }
    
    if ($error){
	carp $error;
	return (1, undef);
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
        carp "Can't authorize on switch $self->{'switch_ip'} connect_type $connect_type with user $self->{'username'}, error: $error";
	return (2, undef);
    }
    $prompt=~s/[\x0a\x0d]+/\n/g;
    my @prompt=split("\n", $prompt);
    $prompt=$prompt[$#prompt].'#';
    $self->{'prompt'}=$prompt;
    $self->send_config_cmd(10, "disable clipaging");
    return (undef, $self);
}

sub telnet_connect {
    my $self=shift;
    
    my $telnet_cmd=defined $self->{'cmd'} ? $self->{'cmd'} : '/usr/bin/telnet';
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

    $exp->log_stdout(0);
    $exp->log_file($self->{'log_file'}) if ($self->{'debug_enable'} == 1);

    $self->{'exp_obj'}=$exp;

    return undef;
}

sub ssh_connect {
    my $self=shift;
    
    my $ssh_cmd=defined $self->{'cmd'} ? $self->{'cmd'} : '/usr/bin/ssh';
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

    $exp->log_stdout(0);
    $exp->log_file($self->{'log_file'}) if ($self->{'debug_enable'} == 1);

    $self->{'exp_obj'}=$exp;

    return undef;
}

sub console_connect {

    my $self=shift;
    my $error;
    
    my $console_cmd=$self->{'cmd'};
    my $dev=$self->{'dev_name'};
    my $speed=$self->{'line_speed'};

    return "$! $console_cmd" unless (-x $console_cmd);
    return "$dev not symbol device" unless ( -c $dev);
    return "uncorrect speed: $speed" unless ($speed=~m/\d+/);

    my $basename=$console_cmd;
    $basename=~s/.*\///;

    my $exp;
    if ($basename eq 'cu'){
	if (! ($exp=Expect->spawn("$console_cmd -l $dev -s $speed"))){
	    $error="can't spawn $console_cmd -l $dev -s $speed";
	    return $error;
	}

	$exp->log_stdout(0);
	$exp->log_file($self->{'log_file'}) if ($self->{'debug_enable'} == 1);

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

	$exp->log_stdout(0);
	$exp->log_file($self->{'log_file'}) if ($self->{'debug_enable'} == 1);

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
    if (! (my $socket=IO::Socket::INET->new(PeerAddr=> $ip, PeerPort=>"$port", Proto=>"tcp", Type=>SOCK_STREAM, Timeout=> 2))){
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
        return ("Command 'show config current_config' error: $error", undef, undef, undef, undef);
    }
    $config=$config_tmp.$config;
    $config=~s/([^\x0d])\x0a\x0d/$1/g;
    $config=~s/\x0d\x0a\x0d/\n/g;
    foreach my $line (split ("\n", $config)){
	$line=~s/^\s+//;
	$line=~s/\W+$//;
	$line=~s/\s+/ /g;
	next if ($line=~m/^(?:\*|show|$)/);
	next if ($line=~m/^\#/);
	$config{$line}=1;
    }
    $self->{'current_switch_config'}=\%config;
    
    return (undef, sort keys %config);
}

sub get_switch_info {
    my $self=shift;
    
    my $exp=$self->{'exp_obj'};
    my %switch_info;

    $exp->send("show switch\n");
    my $switch_data_tmp;
    my ($error, $switch_data)=($exp->expect(10,
	['-re', 'All\s*$', sub {	my $new_exp = shift;
					$switch_data_tmp=$new_exp->before;
					$new_exp->send("q");
					exp_continue_timeout; }],
	$self->{'prompt'}
    ))[1,3];

    unless ($error eq ''){
        return ("Command 'show switch' error: $error", undef);
    }
    
    $switch_data=$switch_data_tmp.$switch_data;
    $switch_data=~s/[\x0a\x0d]+/\n/g;
    foreach my $line (split("\n", $switch_data)){
	if ($line=~m/^\s*Device\s+Type\s*:\s*(.+?)\s+/){
	    $switch_info{'model'}=$1;
	    next;
	}
	if ($line=~m/^\s*MAC\s+Address\s*:\s*(.+?)$/){
	    $switch_info{'switch_mac'}=$1;
	    next;
	}
	if ($line=~m/^\s*Firmware\s+Version\s*:\s*Build\s+(.+?)$/){
	    $switch_info{'firmware_version'}=$1;
	    next;
	}
	if ($line=~m/^\s*Hardware\s+Version\s*:\s*(.+?)$/){
	    $switch_info{'hardware_version'}=$1;
	    next;
	}
	if ($line=~m/^\s*VLAN\s+Name\s*:\s*(.+?)$/){
	    $switch_info{'mgmt_vlan_name'}=$1;
	    next;
	}
	if ($line=~m/^\s*System\s+Name\s*:\s*(.+?)$/){
	    $switch_info{'system_name'}=$1;
	    next;
	}
    }
    $self->{'switch_info'}=\%switch_info;

    return (undef, %switch_info);
}

sub get_vlan_setting {
    my $self=shift;
    
    my $exp=$self->{'exp_obj'};
    my %vlan_data_current;
    
    $exp->send("show vlan\n");
    my $vlan_data_tmp;
    my ($error, $vlan_data)=($exp->expect(10,
	['-re', 'All\s*$', sub {	my $new_exp = shift;
					$vlan_data_tmp=$new_exp->before;
					$new_exp->send("a");
					exp_continue_timeout; }],
	$self->{'prompt'}
    ))[1,3];

    
    unless ($error eq ''){
        return ("Command 'show vlan' error: $error", undef);
    }
    
    $vlan_data=$vlan_data_tmp.$vlan_data;
    
    $vlan_data=~s/[\x0a\x0d]+/\n/g;
    my $vlan_id;
    my $vlan_name;
    my $vlan_tagged;
    my $vlan_untagged;
    foreach my $line (split("\n",$vlan_data)){
	if ($line=~m/^\s*VID\s+:\s+(\d+)\s+VLAN\s+Name\s+:\s+(.+?)\s*$/){
	    $vlan_id=$1;
	    $vlan_name=$2;
	    $vlan_data_current{$vlan_id}->{'name'}=$vlan_name;
	}
	if ($line=~m/^(?:Current\s+Tagged|Tagged)\s+[Pp]orts\s*:\s+(.+?)\s*$/){
	    $vlan_tagged=$1;
	    $vlan_tagged=~s/\s+//g;
	    if ($vlan_tagged ne ''){
		foreach my $port ($self->range_to_array($vlan_tagged)){
		    $vlan_data_current{$vlan_id}->{'ports'}->{$port} = TAGGED_PORT;
		}
	    }
	}
	if ($line=~m/^(?:Current\s+Untagged|Untagged)\s+[Pp]orts\s*:\s+(.+?)\s*$/){
	    $vlan_untagged=$1;
	    $vlan_untagged=~s/\s+//g;
	    if ($vlan_untagged ne ''){
		foreach my $port ($self->range_to_array($vlan_untagged)){
		    $vlan_data_current{$vlan_id}->{'ports'}->{$port} = UNTAGGED_PORT;
		}
	    }
	}
    }
    $self->{'vlan_data_current'}=\%vlan_data_current;
    
    return (undef, %vlan_data_current);
}

sub set_vlan_setting {
    my $self=shift;
    my %vlan_data=@_;
    
    my %vlan_data_current;
    
    if (exists $self->{'vlan_data_current'}){
	%vlan_data_current=%{(dclone($self->{'vlan_data_current'}))};
    }else{
	(my $error, %vlan_data_current)=$self->get_vlan_setting();
	return ($error, %vlan_data_current) if (defined $error);
    }

    my @vlan_cmd_delete_port;
    my @vlan_cmd_delete_vlan;
    my @vlan_cmd_create_vlan;
    my @vlan_cmd_config_vlan;
	
    foreach my $vlan_id (keys %vlan_data_current){
	unless (exists $vlan_data{$vlan_id}){
	    push (@vlan_cmd_delete_vlan, "delete vlan $vlan_data_current{$vlan_id}->{'name'}");
	}
	foreach my $port (keys %{$vlan_data_current{$vlan_id}->{'ports'}}){
	    if (exists $vlan_data{$vlan_id}->{'ports'}->{$port}){
		if ($vlan_data_current{$vlan_id}->{'ports'}->{$port} == $vlan_data{$vlan_id}->{'ports'}->{$port}){
		    delete ($vlan_data{$vlan_id}->{'ports'}->{$port});
		}
	    }else{
		$vlan_data{$vlan_id}->{'ports'}->{$port}=DELETE_PORT;
	    }
	}
    }
    
    foreach my $vlan_id (keys %vlan_data){
	my (@tagged_ports, @untagged_ports, @delete_ports);
	foreach my $port (keys %{$vlan_data{$vlan_id}->{'ports'}}){
	     if ($vlan_data{$vlan_id}->{'ports'}->{$port} == TAGGED_PORT){
		push (@tagged_ports, $port);
	    }elsif ($vlan_data{$vlan_id}->{'ports'}->{$port} == UNTAGGED_PORT){
		push (@untagged_ports, $port);
	    }elsif ($vlan_data{$vlan_id}->{'ports'}->{$port} == DELETE_PORT){
		push (@delete_ports, $port);
	    }
	}
	unless (exists $vlan_data_current{$vlan_id}){
	    push (@vlan_cmd_create_vlan, "create vlan $vlan_data{$vlan_id}->{'name'} tag $vlan_id");
	    $vlan_data_current{$vlan_id}->{'name'}=$vlan_data{$vlan_id}->{'name'};
	}
	push (@vlan_cmd_config_vlan, "config vlan $vlan_data_current{$vlan_id}->{'name'} add tagged ".join (",",sort {$a <=> $b} @tagged_ports)) if (@tagged_ports);
	push (@vlan_cmd_config_vlan, "config vlan $vlan_data_current{$vlan_id}->{'name'} add untagged ".join (",",sort {$a <=> $b} @untagged_ports)) if (@untagged_ports);
	push (@vlan_cmd_delete_port, "config vlan $vlan_data_current{$vlan_id}->{'name'} delete ".join (",",sort {$a <=> $b} @delete_ports)) if (@delete_ports);
    }
    my @error;
    if (@vlan_cmd_delete_port){
	push (@error, $self->send_config_cmd_bulk(10,\@vlan_cmd_delete_port));
    }
    if (@vlan_cmd_delete_vlan){
	push (@error, $self->send_config_cmd_bulk(10,\@vlan_cmd_delete_vlan));
    }
    if (@vlan_cmd_create_vlan){
	push (@error, $self->send_config_cmd_bulk(10,\@vlan_cmd_create_vlan));
    }
    if (@vlan_cmd_config_vlan){
	push (@error, $self->send_config_cmd_bulk(10,\@vlan_cmd_config_vlan));
    }
    (my $error_get_vlan, %vlan_data_current)=$self->get_vlan_setting();
    my $error=join("\n", grep(defined, (@error, $error_get_vlan)));
    $error=undef if ($error eq '');
    return ($error, %vlan_data_current);
}

# Need upgrade for this function

#sub get_ports_setting{
#    my $self=shift;

#    my $exp=$self->{'exp_obj'};
#    $exp->send("show ports\n");

#    my $ports_data_tmp;
#    my ($error, $ports_data)=($exp->expect(10,
#	['-re', 'Refresh\s*$', sub {	my $new_exp = shift;
#					$ports_data_tmp=$new_exp->before;
#					$new_exp->send("q");
#					exp_continue_timeout; }],
#	$self->{'prompt'}
#    ))[1,3];

#    unless ($error eq ''){
#        return ("Command 'show ports' error: $error", undef);
#    }
    
#    $ports_data=$ports_data_tmp.$ports_data;
#    my %ports_data;
#    foreach my $line (split("\n", $ports_data)){
#	if ($line=~/^\s*(\d+)\s*(\([CF]\))?\s+(\w+)/){
#	    $ports_data{$1}=$3;
#	}
#    }
#    return (undef, %ports_data);
#}

sub get_all_ports{
    my $self=shift;

    my $exp=$self->{'exp_obj'};
    $exp->send("show lacp_port\n");
    
    my $ports_data_tmp;
    my ($error, $ports_data)=($exp->expect(10,
	['-re', 'All\s*$', sub {	my $new_exp = shift;
					$ports_data_tmp=$new_exp->before;
					$new_exp->send("a");
					exp_continue_timeout; }],
	$self->{'prompt'}
    ))[1,3];

    unless ($error eq ''){
        return ("Command 'show lacp_port' error: $error", undef);
    }

    $ports_data=$ports_data_tmp.$ports_data;
    $ports_data=~s/[\x0a\x0d]+/\n/g;
    my %ports_data;
    foreach my $line (split("\n", $ports_data)){
	if ($line=~/^\s*(\d+)\s+(\w+)\s*$/){
	    $ports_data{$1}=1;
	}
    }
    $self->{'ports_all'}=\%ports_data;
    return (undef, %ports_data);
}

sub set_lldp_setting{
    my $self=shift;
    my @lldp_enabled_ports=@_;
    
    my %lldp_enabled_ports=map {$_ => 1} @lldp_enabled_ports;
    
    my ($error, %ports_data);
    unless (exists $self->{'ports_all'}){
	($error, %ports_data)=$self->get_all_ports();
	return $error if (defined $error);
    }else{
	%ports_data=%{$self->{'ports_all'}};
    }
    
    my %switch_info;
    unless (defined $self->{'switch_info'}){
	($error, %switch_info)=$self->get_switch_info();
	return $error if (defined $error);
    }else{
	%switch_info=%{$self->{'switch_info'}};
    }
    my @lldp_add;
    my @lldp_delete;
    foreach my $port (keys %ports_data){
	if (exists $lldp_enabled_ports{$port}){
	    push (@lldp_add, $port);
	}else{
	    push (@lldp_delete, $port);
	}
    }
    
    my $system_name=$self->{'switch_ip'};
    $system_name=~s/\./\-/g;
    
    my @lldp_cmd_config;
    push (@lldp_cmd_config, "enable lldp");
    push (@lldp_cmd_config, "config lldp message_tx_interval 30");
    push (@lldp_cmd_config, "config lldp tx_delay 2");
    push (@lldp_cmd_config, "config lldp notification_interval 5");
    push (@lldp_cmd_config, "config lldp message_tx_interval 30");
    if ($switch_info{'model'}=~m/^DES-30/){
	foreach my $port (sort {$a <=> $b} keys %ports_data){
	    push (@lldp_cmd_config, "config lldp ports $port notification disable");
	    push (@lldp_cmd_config, "config lldp ports $port basic_tlvs port_description system_name system_description system_capabilities enable");
	    push (@lldp_cmd_config, "config lldp ports $port dot1_tlv_pvid enable");
	    push (@lldp_cmd_config, "config lldp ports $port dot3_tlvs mac_phy_configuration_status link_aggregation maximum_frame_size enable");
	}
	map {push (@lldp_cmd_config, "config lldp ports $_ admin_status disable")} sort {$a <=> $b} @lldp_delete;
	map {push (@lldp_cmd_config, "config lldp ports $_ admin_status tx_and_rx")} sort {$a <=> $b} @lldp_add;
    }else{
	push (@lldp_cmd_config, "config lldp ports ".$self->array_to_range(keys %ports_data)." notification disable");
	push (@lldp_cmd_config, "config lldp ports ".$self->array_to_range(@lldp_delete)." admin_status rx_only");
	push (@lldp_cmd_config, "config lldp ports ".$self->array_to_range(keys %ports_data)." basic_tlvs port_description system_name system_description system_capabilities enable");
	push (@lldp_cmd_config, "config lldp ports ".$self->array_to_range(keys %ports_data)." dot1_tlv_pvid enable");
	push (@lldp_cmd_config, "config lldp ports ".$self->array_to_range(keys %ports_data)." dot3_tlvs mac_phy_configuration_status link_aggregation maximum_frame_size enable");
	push (@lldp_cmd_config, "config lldp ports ".$self->array_to_range(@lldp_add)." admin_status tx_and_rx");
    }
    push (@lldp_cmd_config, "config snmp system_name $system_name");
    $error=$self->send_config_cmd_bulk(10,\@lldp_cmd_config);

    return $error;
}

sub get_arp_table {
    my $self=shift;
    
    my $exp=$self->{'exp_obj'};
    $exp->send("show arpentry\n");
    
    my $arp_data_tmp;
    my ($error, $arp_data)=($exp->expect(20,
	['-re', 'All\s*$', sub {	my $new_exp = shift;
					$arp_data_tmp=$new_exp->before;
					$new_exp->send("a");
					exp_continue_timeout; }],
	$self->{'prompt'}
    ))[1,3];

    unless ($error eq ''){
        return ("Command 'show arpentry' error: $error", undef);
    }

    $arp_data=$arp_data_tmp.$arp_data;
    $arp_data=~s/[\x0a\x0d]+/\n/g;
    my %arp_data;
    foreach my $line (split("\n", $arp_data)){
	if ($line=~/^\s*.+?\s+((?:\d+\.){3}\d+)\s+(.+?)\s+/){
	    my $ip=$1;
	    my $mac=$2;
	    $mac=~s/-//g;
	    $mac=~tr/A-F/a-f/;
	    $arp_data{$ip}=$mac;
	}
    }
    $self->{'arp_table'}=\%arp_data;
    return (undef, %arp_data);
}

sub get_mac_table {
    my $self=shift;
    
    my $exp=$self->{'exp_obj'};
    $exp->send("show fdb\n");
    
    my $mac_data_tmp;
    my ($error, $mac_data)=($exp->expect(20,
	['-re', 'All\s*$', sub {	my $new_exp = shift;
					$mac_data_tmp=$new_exp->before;
					$new_exp->send("a");
					exp_continue_timeout; }],
	$self->{'prompt'}
    ))[1,3];

    unless ($error eq ''){
        return ("Command 'show fdb' error: $error", undef);
    }

    $mac_data=$mac_data_tmp.$mac_data;
    $mac_data=~s/[\x0a\x0d]+/\n/g;
    my %mac_data;
    foreach my $line (split("\n", $mac_data)){
	if ($line=~/^\s*\d+\s+.+?\s+((?:[0-9A-F]{2}-){5}[0-9A-F]{2})\s+(.+?)\s+/){
	    my $mac=$1;
	    my $port=$2;
	    $mac=~s/-//g;
	    $mac=~tr/A-F/a-f/;
	    push (@{$mac_data{$mac}}, $port);
	}
    }
    $self->{'mac_table'}=\%mac_data;
    return (undef, %mac_data);
}

sub send_config_cmd {
    my $self=shift;
    my $timeout=shift;
    my $cmd=shift;
    
    my $exp=$self->{'exp_obj'};
    my $prompt=$self->{'prompt'};
    
    $exp->log_file($self->{'log_file'}) if ($self->{'debug_enable'} == 2);

    $exp->send("$cmd\n");
    my ($error, $output)=($exp->expect($timeout, $prompt))[1,3];
    unless ($error eq ''){
	$exp->log_file(undef) if ($self->{'debug_enable'} == 2);
	return "'$cmd' not set error: $error";
    }else{
	my ($error, $result);
	$output=~s/[\x0a\x0d]+/\n/g;
	my @output=split("\n",$output);
	$result=$output[$#output];
	$result=~s/^\s+//;
	$result=~s/\s+$//;
	if ($result eq 'Fail'){
	    $error=join(" ", @output[2..$#output-1]) ;
	    carp "Error command: '$cmd'\n";
	    carp "Error message: $error\n\n";
	}
    }
    $exp->log_file(undef) if ($self->{'debug_enable'} == 2);
    return undef;
}

sub send_config_cmd_bulk {
    my $self=shift;
    my $timeout=shift;
    my $cmd_ref=shift;
    
    my $exp=$self->{'exp_obj'};
    my $prompt=$self->{'prompt'};

    $self->read_config() unless (exists $self->{'current_switch_config'});
    
    foreach my $cmd (@$cmd_ref){
	unless(exists $self->{'current_switch_config'}->{$cmd}){
	    my $error=$self->send_config_cmd($timeout,$cmd);
	    if (defined $error){
		return $error;
	    }else{
		$self->{'current_switch_config'}->{$cmd}=1;
	    }
	}
    }
    return undef;
}


# convert 1-2,5,6-8 to array (1,2,5,6,7,8)

sub range_to_array{
    my $self=shift;
    my $range_scalar=shift;
    my @range_array;
    foreach my $range (split (",",$range_scalar)){
        if ($range=~m/^(\d+)-(\d+)$/){
            my $min=$1;
            my $max=$2;
            push (@range_array, ($min..$max));
        }else{
            push (@range_array, $range);
        }
    }
    return @range_array;
}

sub array_to_range{
    my $self=shift;
    my @array=@_;

    my @range_scalar;
    my @range_array;

    foreach my $number (sort {$a <=> $b} @array){
	if ($#range_array>=0 && $range_array[-1]->[-1] + 1 == $number){
	    push (@{$range_array[-1]}, $number);
	}else{
	    push (@range_array, [$number]);
	}
    }

    foreach my $array_ref (@range_array){
	my @local_array=@$array_ref;
	if ($#local_array>0){
	    push (@range_scalar, "$local_array[0]-$local_array[-1]");
	}else{
	    push (@range_scalar, "$local_array[0]");
	}
    }

    return join(",", @range_scalar);
}

return 1;

