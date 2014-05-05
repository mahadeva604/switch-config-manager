#!/usr/bin/perl

use FindBin qw($Bin);
use lib "$Bin";

use strict;
use SCM;
use Storable qw(dclone);
use Data::Compare;
use POSIX ":sys_wait_h";
use Socket;
use Fcntl qw (:DEFAULT :flock);
use Config::General;
use Getopt::Std;
use Data::Dumper;

use constant TAGGED_PORT => 0;
use constant UNTAGGED_PORT => 1;

my ($start_switch_ip, $start_port_ref, $end_switch_ip, $end_port_ref, $force_flag, %vlans)=&read_options();

my $vlan_tree_config = Config::General->new('vlan_tree.conf');
my %vlan_tree_config=$vlan_tree_config->getall;

my @switch_ip=($start_switch_ip, $end_switch_ip);

my %ports=(
    $start_switch_ip => $start_port_ref,
    $end_switch_ip => $end_port_ref
);

my $log_file=$vlan_tree_config{'log'}->{'log_file'};
my $debug_flag=$vlan_tree_config{'debug'}->{'debug_enable'};
my %users=%{$vlan_tree_config{'users'}->{'user'}};

my @connect_type=('ssh','telnet');

my %switch_data;
my @switch_path;

while (my $switch_ip = shift @switch_ip){

	my $scm=connect_to_switch($switch_ip);
	push (@switch_path, $switch_ip);

	if (defined $scm){
	    my $error;
	    
	    $switch_data{$switch_ip}->{'scm'}=$scm;
	    
	    $error=$scm->send_config_cmd(10,"disable gvrp");
	    &PrintLog("ERROR: send_config_cmd(\"disable gvrp\") $error",1) && exit if (defined $error);
	    
	    my ($error, %switch_info)=$scm->get_switch_info();
	    &PrintLog("ERROR: get_switch_info() $error",1) && exit if (defined $error);
	    $switch_data{$switch_ip}->{'mac_addr'}=$switch_info{'switch_mac'};
	    
	    my $must_be_system_name=$switch_ip;
	    $must_be_system_name=~s/\./-/g;
	    if ($must_be_system_name ne $switch_info{'system_name'}){
		
		$error=$scm->send_config_cmd(10, "config snmp system_name $must_be_system_name");
		&PrintLog("ERROR: Can't change system name on $switch_ip $error", 1) && exit if (defined $error);
		
		$error=$scm->send_config_cmd(60, "save");
		&PrintLog("ERROR: Can't save config on $switch_ip $error", 1) && exit if (defined $error);
		
		&PrintLog("ERROR: Change system name on switch $switch_ip, restart programm", 1);
		exit;
	    }

	    my $end_switch_mac;
	    
	    unless (defined $switch_data{$end_switch_ip}->{'mac_addr'}){
		($error, my %arp_table)=$scm->get_arp_table($end_switch_ip);
		&PrintLog("ERROR: $switch_ip get_arp_table() $error",1) && exit if (defined $error);
	    
		$end_switch_mac=$arp_table{$end_switch_ip};

		unless (defined $end_switch_mac){
		    $scm->send_config_cmd(10, "ping $end_switch_ip times 3");
		    %arp_table=();
		    ($error, %arp_table)=$scm->get_arp_table($end_switch_ip);
		    &PrintLog("ERROR: $switch_ip get_arp_table() $error",1) && exit if (defined $error);
		    $end_switch_mac=$arp_table{$end_switch_ip};
		}
		$switch_data{$end_switch_ip}->{'mac_addr'}=$end_switch_mac;
	    }else{
		$end_switch_mac=$switch_data{$end_switch_ip}->{'mac_addr'};
	    }

	    &PrintLog("ERROR: $switch_ip can't find mac address of $end_switch_ip",1) && exit unless (defined $end_switch_mac);
	    
	    if (defined (my $prev_switch=$switch_path[-2])){
		($error, my %mac_table)=$scm->get_mac_table($switch_data{$prev_switch}->{'mac_addr'});
		&PrintLog("ERROR: $switch_ip get_mac_table() $error",1) && exit if (defined $error);
		
		my %uplink_port;
		
		unless (defined $mac_table{$switch_data{$prev_switch}->{'mac_addr'}}){
		    $scm->send_config_cmd(10, "ping $prev_switch times 3");
		    ($error, %mac_table)=$scm->get_mac_table($switch_data{$prev_switch}->{'mac_addr'});
		    &PrintLog("ERROR: $switch_ip get_mac_table() $error",1) && exit if (defined $error);
		    %uplink_port=%{$mac_table{$switch_data{$prev_switch}->{'mac_addr'}}};
		}else{
		    %uplink_port=%{$mac_table{$switch_data{$prev_switch}->{'mac_addr'}}};
		}
		&PrintLog("ERROR: $switch_ip can't find uplink port for mac address $end_switch_mac",1) && exit if ((scalar keys %uplink_port) == 0);
		&PrintLog("ERROR: $switch_ip Find few uplink port for mac address $end_switch_mac",1) && exit if ((scalar keys %uplink_port) > 1);
		push (@{$switch_data{$switch_ip}->{'uplinks'}}, keys %uplink_port);
	    }
	
	    if ($switch_ip ne $end_switch_ip){
		($error, my %mac_table)=$scm->get_mac_table($end_switch_mac);
		&PrintLog("ERROR: $switch_ip get_mac_table() $error",1) && exit if (defined $error);

		my %uplink_port=%{$mac_table{$end_switch_mac}};
		&PrintLog("ERROR: $switch_ip can't find uplink port for mac address $end_switch_mac",1) && exit if ((scalar keys %uplink_port) == 0);
		&PrintLog("ERROR: $switch_ip Find few uplink port for mac address $end_switch_mac",1) && exit if ((scalar keys %uplink_port) > 1);
		
		push (@{$switch_data{$switch_ip}->{'uplinks'}}, keys %uplink_port);
		my $uplink_port=(keys %uplink_port)[0];
	    
		($error, my %lldp_neighbors)=$scm->get_lldp_neighbors($uplink_port);
		&PrintLog("ERROR: $switch_ip get_lldp_neighbors() $error",1) && exit if (defined $error);

		my $lldp_system_name=$lldp_neighbors{$uplink_port}->{'system_name'};
		&PrintLog("ERROR: $switch_ip Uncorrect lldp system name $lldp_system_name",1) && exit unless ($lldp_system_name=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)-){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/);
	    
		my $next_switch_ip=$lldp_system_name;
		$next_switch_ip=~s/-/./g;
	    
		unshift (@switch_ip, $next_switch_ip) if ($next_switch_ip ne $end_switch_ip);
	    }
	    
	    my $vlan_data_new_ref=&check_vlan_setting(\$switch_data{$switch_ip}, $ports{$switch_ip}, \%vlans);
	    $switch_data{$switch_ip}->{'vlan_data_new'}=$vlan_data_new_ref;
	}
}

foreach my $switch_ip (@switch_path){
    my $scm=$switch_data{$switch_ip}->{'scm'};

# Check connection

    my $error=$scm->send_config_cmd(10,"disable clipaging");
    my $error_code=(split(/\s+/,$error))[-1];

# Reconnect

    if ($error_code eq '2:EOF'){
	&PrintLog("Warning: reconnect to $switch_ip", 1);
	$scm->reconnect();
    }
    
    $error=$scm->send_config_cmd(60, "save");
    &PrintLog("ERROR: Can't save config on $switch_ip $error", 1) && exit if (defined $error);
}

&PrintLog("Done", 1);

sub connect_to_switch {
    my $switch_ip=shift;
    my $scm;
    foreach my $connect_type (@connect_type){
	foreach my $user_name (keys %users){
	    (my $error, $scm)=SCM->connect({
	        'connect_type'	=> $connect_type,
	        'switch_ip'		=> $switch_ip,
		'username'		=> $user_name,
		'password'		=> $users{$user_name}->{'password'},
		'log_file'		=> \&PrintLog,
		'debug_enable'	=> $debug_flag
	    });
	    last if ($error==1 or defined $scm);
	}
	last if (defined $scm);
    }
    return $scm;
}


sub PrintLog {
    my $text=shift;
    my $stdout_flag=shift;
    sysopen(LOG_FILE,$log_file,O_APPEND | O_WRONLY | O_CREAT) or return 1;
    flock (LOG_FILE, LOCK_EX);
    my $date=scalar localtime;
    $text=~s/[\x0a\x0d]+/\n/g;
    foreach my $line (split ("\n", $text)){
	print LOG_FILE "$date\t$$\t$line\n";
    }
    close LOG_FILE;
    print "$text\n" if ($stdout_flag);
    return 1;
}

sub check_vlan_setting {
    my $switch_data=shift;
    my $ports_ref=shift;
    my %vlans=%{(shift)};
    
    my $scm=$$switch_data->{'scm'};
    my $switch_ip=$scm->{'switch_ip'};
    my $mgmt_vlan_name=$scm->{'switch_info'}->{'mgmt_vlan_name'};
    my @uplinks=@{$$switch_data->{'uplinks'}};
    my $error;
    
    ($error, my %vlan_data_current)=$scm->get_vlan_setting();
    &PrintLog("ERROR: $switch_ip get_vlan_setting() $error",1) && exit if (defined $error);
    
    my $mgmt_vlan_id;
    foreach my $vlan_id (keys %vlan_data_current){
	if ($vlan_data_current{$vlan_id}->{'name'} eq $mgmt_vlan_name){
	    $mgmt_vlan_id=$vlan_id;
	    last;
	}
    }
    
    &PrintLog("ERROR: $switch_ip, you can't setting up mgmt vlan $mgmt_vlan_id", 1) && exit if (exists $vlans{$mgmt_vlan_id});
    
    my %vlan_data_new=%{dclone(\%vlan_data_current)};
    
    if (defined $ports_ref){
	
	my %ports=%{$ports_ref};
	
	($error, my %ports_data)=$scm->get_all_ports();
	&PrintLog("ERROR: $switch_ip get_all_ports() $error",1) && exit if (defined $error);

	foreach my $port (keys %ports){
	    &PrintLog("ERROR: $switch_ip haven't port $port", 1) && exit unless (exists $ports_data{$port});
	}

	my $untagged_vlan;
    
	foreach my $vlan_id (keys %vlans){
	    ($untagged_vlan=$vlan_id) && last if ($vlans{$vlan_id} == UNTAGGED_PORT);
	}
    
#    print Dumper($switch_data);

	my @error;
	my @warning;
	foreach my $vlan_id (keys %vlan_data_new){
	    foreach my $port (keys %{$vlan_data_new{$vlan_id}->{'ports'}}){
		if (exists $ports{$port}){
		    push (@error, "Error: $port is uplink (have mgmt vlan $vlan_id $mgmt_vlan_name)") && next if ($vlan_data_new{$vlan_id}->{'name'} eq $mgmt_vlan_name);
		    if (defined ($untagged_vlan)){
			delete $vlan_data_new{$vlan_id}->{'ports'}->{$port} if ($vlan_data_new{$vlan_id}->{'ports'}->{$port} == UNTAGGED_PORT && $vlan_data_new{$vlan_id}->{'ports'}->{$port} != $untagged_vlan);
			push (@warning, "Warning: I should delete untagged vlan $vlan_id on port $port switch ip $switch_ip");
		    }
		    delete $vlan_data_new{$vlan_id}->{'ports'}->{$port} if ($force_flag && not exists $vlans{$vlan_id});
		}
	    }
	}
    
	(map {&PrintLog($_,1)} @error) && exit if (@error);
	map {&PrintLog($_,1)} @warning if (@warning);
    
        foreach my $vlan_id_new (keys %vlans){
	    $vlan_data_new{$vlan_id_new}->{'name'}=$vlan_id_new unless (exists $vlan_data_new{$vlan_id_new}->{'name'});
	    foreach my $port (keys %ports){
		$vlan_data_new{$vlan_id_new}->{'ports'}->{$port}=$vlans{$vlan_id_new};
	    }
	    foreach my $port (@uplinks){
		$vlan_data_new{$vlan_id_new}->{'ports'}->{$port}=TAGGED_PORT;
	    }
	}
    }
    
    foreach my $vlan_id_new (keys %vlans){
	$vlan_data_new{$vlan_id_new}->{'name'}=$vlan_id_new unless (exists $vlan_data_new{$vlan_id_new}->{'name'});
	foreach my $port (@uplinks){
	    $vlan_data_new{$vlan_id_new}->{'ports'}->{$port}=TAGGED_PORT;
	}
    }
    
    return \%vlan_data_new;
}

sub read_options {
    my %options=();
    my %return_options;
    getopts("s:d:v:f", \%options);
    my $force_flag=0;
    if (exists $options{'s'} and exists $options{'d'} and exists $options{'v'}){
	my ($start_switch_ip, $start_ports_ref)=&parse_switch_ip_option($options{'s'});
	my ($end_switch_ip, $end_ports_ref)=&parse_switch_ip_option($options{'d'});
	my %vlans=&parse_vlan_option($options{'v'});
	$force_flag=1 if (exists $options{'f'});
	return ($start_switch_ip, $start_ports_ref, $end_switch_ip, $end_ports_ref, $force_flag, %vlans);
    }else{
	&help();
        exit;
    }
}

sub parse_switch_ip_option{
    my $option=shift;
    my ($switch_ip, $port_list)=split(":",$option);
    &help("Uncorrect switch ip: $switch_ip") && exit unless ($switch_ip=~m/(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/);
    my %ports;
    if (defined $port_list){
	foreach my $port_range (split(/\s*,\s*/,$port_list)){
    	    if ($port_range=~m/^(\d+)-(\d+)$/){
        	my $min=$1;
        	my $max=$2;
        	if ($min<$max){
        	    %ports=(%ports, map {$_ => 1} ($min..$max));
        	}else{
        	    &help("Uncorrected port range (min and max): $port_list");
        	    exit;
        	}
    	    }elsif($port_range=~m/^\d+$/){
        	$ports{$port_range}=1;
    	    }else{
    		&help("Uncorrected port range");
        	exit;
    	    }
	}
    }
    return ($switch_ip, \%ports);
}

sub parse_vlan_option{
    my $vlan_list=shift;
    my %vlans;
    my $untagged_vlan=0;
    foreach my $vlan_range (split(/\s*,\s*/,$vlan_list)){
	if ($vlan_range=~m/^(\d+)-(\d+)$/){
	    my $min=$1;
    	    my $max=$2;
    	    if ($min<$max){
    		%vlans=(%vlans, map {$_ => TAGGED_PORT} ($min..$max));
    	    }else{
    		&help("Uncorrect vlan range (min and max): $vlan_list");
        	exit;
    	    }
	}elsif($vlan_range=~m/^(\d+)u?$/){
	    my $vlan_id=$1;
	    if ($vlan_range=~m/u$/){
		$vlans{$vlan_id}=UNTAGGED_PORT;
		$untagged_vlan++;
	    }else{
		$vlans{$vlan_id}=TAGGED_PORT;
	    }
	}else{
	    &help("Uncorrect vlan range: $vlan_list");
	    exit;
	}
    }
    &help("More that one untagged vlan: $vlan_list") && exit if ($untagged_vlan>1);
    return %vlans;
}

sub help {
    my $addition_message=shift;
    print "Usage :\t\t$0 -s switch_ip[:port_list] -d switch_ip[:port_list] -v vlan_list [-f]\n";
    print "Comment :\t$addition_message\n" if (defined $addition_message);
}
