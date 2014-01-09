#!/usr/bin/perl

use strict;
use Expect;
use IO::Socket::INET;
use Config::General;
use Getopt::Std;
use Data::Dumper;

$SIG{'INT'} = sub {&kill_screen;};

use constant TAGGED_PORT => 0;
use constant UNTAGGED_PORT => 1;
use constant DELETE_PORT => 2;

my $scm_config = Config::General->new('scm.conf');
my %configure=&check_config('switch.conf');

my %scm_config=$scm_config->getall;
my $telnet_cmd=$scm_config{'path'}->{'telnet'};
my $ssh_cmd=$scm_config{'path'}->{'ssh'};
my $console_cmd=$scm_config{'path'}->{'console'};

my $enable_stdout=0;
$enable_stdout=$scm_config{'debug'}->{'debug_enable'} if (exists $scm_config{'debug'}->{'debug_enable'});

my %options=&read_options();

my $connect_type=$options{'connect_type'};
my $username=$options{'user_name'};
my $password=$options{'password'};
my $dev_name;
my $line_speed;
my $switch_ip;
$dev_name=$options{'dev_name'} if (exists $options{'dev_name'});
$line_speed=$options{'line_speed'} if (exists $options{'line_speed'});
$switch_ip=$options{'switch_ip'} if (exists $options{'switch_ip'});

my ($exp, $prompt)=&connect_to_switch();

&send_config_cmd($exp,10,"disable clipaging",$prompt);

my ($current_switch_config, $vendor, $model, $firmware)=&read_config($exp);
my %current_switch_config;
%current_switch_config=%$current_switch_config;

&stuff_setting($exp);

if (exists $configure{'console'}){
    unless ($connect_type eq 'console'){
	&console_setting($exp);
    }else{
	print "Warning: Skip console setting up\n";
    }
}

if (exists $configure{'stuff'}->{'prompt'}){
    $prompt=&prompt_setting($exp);
}

if (exists $configure{'account'}){
    &account_setting($exp);
}

if (exists $configure{'enable'}){
    &enable_setting($exp);
}

if (exists $configure{'ssh'}){
    &ssh_setting($exp);
}

if (exists $configure{'telnet'}){
    &telnet_setting($exp);
}

if (exists $configure{'web'}){
    &web_setting($exp);
}

if (exists $configure{'snmp'}){
    &snmp_setting($exp);
}

my %vlan_data_current;
if (exists $configure{'vlans'}){
    %vlan_data_current=&vlan_interface_setting($exp);
}

if (exists $configure{'vlans'} and exists $configure{'mgmt'}
    and (exists $options{'mgmt_ip'} or exists $configure{'mgmt'}->{'ipaddr'})){
    if ($connect_type eq 'console'){
	&mgmt_interface_setting($exp);
    }else{
	print "Warning: Skip setting up management interface\n";
    }
}

if (exists $configure{'authen'}){
    &authen_setting($exp);
}

&send_config_cmd($exp,600,"save",$prompt);

sub stuff_setting{
    my $exp=shift;
    my @stuff_cmd;
    push (@stuff_cmd, "disable autoconfig");
    push (@stuff_cmd, "enable password encryption");
    push (@stuff_cmd, "enable password_recovery") if ($model=~m/^DES-3[25]/);
    push (@stuff_cmd, "disable cpu_interface_filtering");
    &send_config_cmd_bulk($exp,10,\@stuff_cmd,$prompt);
}

sub console_setting{
    my $exp=shift;
    my $console_speed=$configure{'console'}->{'speed'};
    my $auto_logout=$configure{'console'}->{'auto_logout'};
    my @console_cmd;
    push (@console_cmd, "config serial_port baud_rate $console_speed auto_logout ".$auto_logout."_minutes");
    &send_config_cmd_bulk($exp,10,\@console_cmd,$prompt);
}

sub prompt_setting{
    my $exp=shift;
    my $new_prompt=$configure{'stuff'}->{'prompt'};
    my $returned_prompt;
    my $error;
    my $new_prompt_cmd="config command_prompt $new_prompt";
    unless(exists $current_switch_config{$new_prompt_cmd}){
	$exp->send("$new_prompt_cmd\n");
	($error, $returned_prompt)=($exp->expect(10,'#'))[1,3];
	unless ($error eq ''){
	    die "'$new_prompt_cmd' not set error: $error";
	}
	$returned_prompt=~s/[\x0a\x0d]+/\n/g;
	my @prompt=split("\n", $returned_prompt);
	$returned_prompt=$prompt[$#prompt].'#';
    }else{
	$returned_prompt=$prompt;
    }
    return $returned_prompt;
}

sub account_setting{
	my $exp=shift;
	my %users=%{$configure{'account'}->{'user'}};
	my $delete_accounts_flag=$configure{'account'}->{'clear_users_mode'};
	$exp->send("show account\n");
	my ($error, $account_data)=($exp->expect(10,$prompt))[1,3];
	unless ($error eq ''){
    	    die "Command 'show account' error: $error";
	}
	$account_data=~s/[\x0a\x0d]+/\n/g;
	my @cmd;
	foreach my $line (split ("\n", $account_data)){
	    if ($line=~m/\s*(.+?)\s+(Admin|User)\s*$/){
		my $user=$1;
		my $access_level=$2;
		if (exists $users{$user}){
		    if ($users{$user}->{'access_level'}=~m/$access_level/i){
			delete $users{$user};
		    }else{
			push (@cmd,['delete',$user]);
			push (@cmd,['add',$user]);
		    }
		}else{
		    if ($delete_accounts_flag){
			push (@cmd,['delete',$user]);
		    }
		}
	    }
	}
	foreach my $user (keys %users){
	    push (@cmd,['add',$user]);
	}
	foreach my $cmd_ref (@cmd){
	    my $cmd=$cmd_ref->[0];
	    my $user=$cmd_ref->[1];
	    if ($cmd eq 'delete'){
		&send_config_cmd($exp,10,"delete account $user",$prompt)
	    }elsif($cmd eq  'add'){
		my $access_level=$users{$user}->{'access_level'};
		my $password=$users{$user}->{'password'};
		$exp->send("create account $access_level $user\n");
		my $error=($exp->expect(10,
			[ 'Enter a case-sensitive new password:',
				sub {	my $self = shift;
		                	$self->send("$password\n");
		                        exp_continue; }],
			[ 'Enter the new password again for confirmation:',
				sub {	my $self = shift;
		                        $self->send("$password\n");
		    	                exp_continue; }],
		    	$prompt
		))[1];
		unless ($error eq ''){
    		    die "Command 'create account $access_level $user' error: $error";
		}
	    }
	}
}

sub enable_setting{
    my $exp=shift;
    my $old_enable_password=$configure{'enable'}->{'old_enable_password'};
    my $enable_password=$configure{'enable'}->{'enable_password'};
    $exp->send("config admin local_enable\n");
    my $error=($exp->expect(10,
	    [ 'Enter the old password:',
		sub {	my $self = shift;
		    	$self->send("$old_enable_password\n");
		        exp_continue; }],
	    [ 'Enter the case-sensitive new password:',
		sub {	my $self = shift;
	                $self->send("$enable_password\n");
	                exp_continue; }],
	    [ 'Enter the new password again for confirmation:',
		sub {	my $self = shift;
	                $self->send("$enable_password\n");
	                exp_continue; }],
	    $prompt
	))[1];
	unless ($error eq ''){
    	    die "Command 'config admin local_enable' error: $error";
	}
}

sub ssh_setting{
    my $exp=shift;
    my $ssh_enable=$configure{'ssh'}->{'ssh_enable'};
    my @ssh_enable_cmd=(
	'enable ssh',
	'config ssh algorithm 3DES enable',
	'config ssh algorithm AES128 enable',
	'config ssh algorithm AES192 enable',
	'config ssh algorithm AES256 enable',
	'config ssh algorithm arcfour enable',
	'config ssh algorithm blowfish enable',
	'config ssh algorithm cast128 enable',
	'config ssh algorithm twofish128 enable',
	'config ssh algorithm twofish192 enable',
	'config ssh algorithm twofish256 enable',
	'config ssh algorithm MD5 enable',
	'config ssh algorithm SHA1 enable',
	'config ssh algorithm RSA enable',
	'config ssh algorithm DSA enable',
	'config ssh authmode password enable',
	'config ssh authmode publickey enable',
	'config ssh authmode hostbased enable',
	'config ssh server maxsession 8',
	'config ssh server contimeout 600',
	'config ssh server authfail 2',
	'config ssh server rekey never'
    );
    my @ssh_disable_cmd=(
	'disable ssh'
    );
    if ($ssh_enable){
	&send_config_cmd_bulk($exp,10,\@ssh_enable_cmd,$prompt);
    }else{
	if ($connect_type eq 'ssh'){
	    print "WARNING: Use other type of connection (not $connect_type) to disable ssh\n";
	    return;
	}
	&send_config_cmd_bulk($exp,10,\@ssh_disable_cmd,$prompt);
    }
}

sub telnet_setting{
    my $exp=shift;
    my $telnet_enable=$configure{'telnet'}->{'telnet_enable'};
    my @telnet_enable_cmd=(
	'enable telnet'
    );
    
    my @telnet_disable_cmd=(
	'disable telnet'
    );
    
    if ($telnet_enable){
	&send_config_cmd_bulk($exp,10,\@telnet_enable_cmd,$prompt);
    }else{
	if ($connect_type eq 'telnet'){
	    print "WARNING: Use other type of connection (not $connect_type) to disable telnet\n";
	    return;
	}
	&send_config_cmd_bulk($exp,10,\@telnet_disable_cmd,$prompt);
    }
}

sub web_setting{
    my $exp=shift;
    my $web_enable=$configure{'web'}->{'web_enable'};
    my $https_prefer=$configure{'web'}->{'ssl_prefer'};
    my @web_enable_cmd=(
	'enable web'
    );
    my @ssl_enable_cmd=(
	'enable ssl',
	'enable ssl ciphersuite RSA_with_RC4_128_MD5',
	'enable ssl ciphersuite RSA_with_3DES_EDE_CBC_SHA',
	'enable ssl ciphersuite DHE_DSS_with_3DES_EDE_CBC_SHA',
	'enable ssl ciphersuite RSA_EXPORT_with_RC4_40_MD5'
	
    );
    if ($model=~m/^DES-35/){
	push (@ssl_enable_cmd, 'config ssl cachetimeout timeout 600');
    }else{
	push (@ssl_enable_cmd, 'config ssl cachetimeout 600');
    }
    my @web_disable_cmd=(
	'disable web'
    );
    push (@web_disable_cmd, 'disable ssl') if $model=~m/^DES-3[25]/;
    
    if ($web_enable){
	if ($https_prefer and $model=~m/^DES-3[25]/){
	    &send_config_cmd_bulk($exp,10,\@ssl_enable_cmd,$prompt);
	}else{
	    &send_config_cmd_bulk($exp,10,\@web_enable_cmd,$prompt);
	}
    }else{
	&send_config_cmd_bulk($exp,10,\@web_disable_cmd,$prompt);
    }
}

sub snmp_setting {
    my $exp=shift;
    my $ro_comm=$configure{'snmp'}->{'ro_comm'};
    my $rw_comm=$configure{'snmp'}->{'rw_comm'};

    $exp->send("show snmp user\n");
    my ($error, $snmp_user_data)=($exp->expect(10,$prompt))[1,3];
    $snmp_user_data=~s/[\x0a\x0d]+/\n/g;
    unless ($error eq ''){
        die "Command 'show snmp user' error: $error";
    }
    my @snmp_cmd;
    my $snmp_user_start_flag=0;
    foreach my $line (split("\n",$snmp_user_data)){
	if ($line=~m/^[-]+/){
	    $snmp_user_start_flag=1;
	    next;
	}
	next unless ($snmp_user_start_flag);
	last if ($line=~m/^Total\s+Entries/);
	if ($line=~m/\s*(\w+)\s+(\w+)\s+V3\s+\w+\s+\w+/){
	    push (@snmp_cmd,"delete snmp user $1");
	}
    }

    my $view_name='CommunityView';
    my %snmp_view;
    $snmp_view{$view_name}->{'1'}='Included';
    $snmp_view{$view_name}->{'1.3.6.1.6.3'}='Excluded';
    $snmp_view{$view_name}->{'1.3.6.1.6.3.1'}='Included';

    $exp->send("show snmp view\n");
    my ($error, $snmp_view_data)=($exp->expect(10,$prompt))[1,3];
    unless ($error eq ''){
        die "Command 'show snmp view' error: $error";
    }
    $snmp_view_data=~s/[\x0a\x0d]+/\n/g;
    my $snmp_view_start_flag=0;
    foreach my $line (split("\n",$snmp_view_data)){
	if ($line=~m/^[-]+/){
	    $snmp_view_start_flag=1;
	    next;
	}
	next unless ($snmp_view_start_flag);
	last if ($line=~m/^Total\s+Entries/);
	if ($line=~m/\s*(\w+)\s+(.+?)\s+(Included|Excluded)/){
	    my $view_name=$1;
	    my $subtree=$2;
	    my $view_type=$3;
	    print join("|",($view_name,$subtree,$view_type)),"\n";
	    if ($snmp_view{$view_name}->{$subtree} eq $view_type){
		delete $snmp_view{$view_name}->{$subtree};
	    }else{
		push (@snmp_cmd,"delete snmp view $view_name $subtree");
	    }
	}
    }
    foreach my $view_name (keys %snmp_view){
	foreach my $subtree (keys %{$snmp_view{$view_name}}){
	    my $view_type=$snmp_view{$view_name}->{$subtree};
	    push (@snmp_cmd,"create snmp view $view_name $subtree view_type $view_type");
	}
    }
    
    $exp->send("show snmp groups\n");
    my ($error, $snmp_groups_data)=($exp->expect(10,$prompt))[1,3];
    unless ($error eq ''){
        die "Command 'show snmp groups' error: $error";
    }
    $snmp_groups_data=~s/[\x0a\x0d]+/\n/g;
    my $group_name;
    my $ro_view_name;
    my $rw_view_name;
    foreach my $line (split("\n", $snmp_groups_data)){
	if ($line=~m/^Group\s+Name\s+:\s+(.+)$/){
	    $group_name=$1;
	}elsif ($line=~m/^ReadView\s+Name\s+:\s+(.+)$/){
	    $ro_view_name=$1;
	}elsif ($line=~m/^WriteView\s+Name\s+:\s*(.+|)$/){
	    $rw_view_name=$1;
	    if ($rw_view_name eq ''){
		unless ($group_name eq $ro_comm and $ro_view_name eq $view_name){
		    push (@snmp_cmd,"delete snmp group $group_name");
		}
	    }else{
		unless ($group_name eq $rw_comm and $ro_view_name eq $view_name and $rw_view_name eq $view_name){
		    push (@snmp_cmd,"delete snmp group $group_name");
		}
	    }
	}
    }
    
    &send_config_cmd_bulk($exp,10,\@snmp_cmd,$prompt);
    @snmp_cmd=();

    my %snmp_comm;
    $snmp_comm{$ro_comm}={
	'view_name'=>$view_name,
	'mode'=>'read_only'
    };
    $snmp_comm{$rw_comm}={
	'view_name'=>$view_name,
	'mode'=>'read_write'
    };

    $exp->send("show snmp community\n");
    my ($error, $snmp_comm_data)=($exp->expect(10,$prompt))[1,3];
    unless ($error eq ''){
        die "Command 'show snmp community' error: $error";
    }
    $snmp_comm_data=~s/[\x0a\x0d]+/\n/g;
    my $snmp_comm_start_flag=0;
    foreach my $line (split("\n",$snmp_comm_data)){
	if ($line=~m/^[-]+/){
	    $snmp_comm_start_flag=1;
	    next;
	}
	next unless ($snmp_comm_start_flag);
	last if ($line=~m/^Total\s+Entries/);
	if ($line=~m/^\s*(.+?)\s+(.+?)\s+(.+)$/){
	    my $comm_name=$1;
	    my $view_name=$2;
	    my $access_mode=$3;
	    unless (exists $snmp_comm{$comm_name} && $snmp_comm{$comm_name}->{'view_name'} eq $view_name && $snmp_comm{$comm_name}->{'mode'} eq $access_mode){
		push (@snmp_cmd, "delete snmp community $comm_name")
	    }else{
		delete ($snmp_comm{$comm_name});
	    }
	}
    }
    foreach my $comm_name (keys %snmp_comm){
	push (@snmp_cmd, "create snmp community $comm_name view $snmp_comm{$comm_name}->{'view_name'} $snmp_comm{$comm_name}->{'mode'}")
    }
    &send_config_cmd_bulk($exp,10,\@snmp_cmd,$prompt);
}

sub vlan_interface_setting {
    my $exp=shift;
    my %vlan_data=%{$configure{'vlans'}->{'vlan'}};
    my %vlan_data_current;
    $exp->send("show vlan\n");
    my ($error, $vlan_data)=($exp->expect(10,$prompt))[1,3];
    unless ($error eq ''){
        die "Command 'show vlan' error: $error";
    }
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
	    $vlan_data{$vlan_id}->{'delete_vlan'}=1 unless (exists $vlan_data{$vlan_id});
	}
	if ($line=~m/^\s*Tagged\s+ports\s+:\s+(.+?)\s*$/){
	    $vlan_tagged=$1;
	    $vlan_tagged=~s/\s+//g;
	    if ($vlan_tagged ne ''){
		foreach my $port (&vlan_range_to_array($vlan_tagged)){
		    if (exists $vlan_data{$vlan_id}->{'ports'}->{$port}){
			delete ($vlan_data{$vlan_id}->{'ports'}->{$port}) if ($vlan_data{$vlan_id}->{'ports'}->{$port} == TAGGED_PORT);
		    }else{
			$vlan_data{$vlan_id}->{'ports'}->{$port}=DELETE_PORT;
		    }
		}
	    }
	}
	if ($line=~m/^\s*Untagged\s+ports\s+:\s+(.+?)\s*$/){
	    $vlan_untagged=$1;
	    $vlan_untagged=~s/\s+//g;
	    if ($vlan_untagged ne ''){
		foreach my $port (&vlan_range_to_array($vlan_untagged)){
		    if (exists $vlan_data{$vlan_id}->{'ports'}->{$port}){
			delete ($vlan_data{$vlan_id}->{'ports'}->{$port}) if ($vlan_data{$vlan_id}->{'ports'}->{$port} == UNTAGGED_PORT);
		    }else{
			$vlan_data{$vlan_id}->{'ports'}->{$port}=DELETE_PORT;
		    }
		}
	    }
	}
    }
    my @vlan_cmd_delete_port;
    my @vlan_cmd_delete_vlan;
    my @vlan_cmd_create_vlan;
    my @vlan_cmd_config_vlan;
    foreach my $vlan_id (keys %vlan_data){
	my @tagged_ports;
	my @untagged_ports;
	my @delete_ports;
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
	push (@vlan_cmd_delete_vlan, "delete vlan $vlan_data_current{$vlan_id}->{'name'}") if (exists $vlan_data{$vlan_id}->{'delete_vlan'});
    }
    &send_config_cmd_bulk($exp,10,\@vlan_cmd_delete_port,$prompt) if (@vlan_cmd_delete_port);
    &send_config_cmd_bulk($exp,10,\@vlan_cmd_delete_vlan,$prompt) if (@vlan_cmd_delete_vlan);
    &send_config_cmd_bulk($exp,10,\@vlan_cmd_create_vlan,$prompt) if (@vlan_cmd_create_vlan);
    &send_config_cmd_bulk($exp,10,\@vlan_cmd_config_vlan,$prompt) if (@vlan_cmd_config_vlan);
    return %vlan_data_current;
}

sub mgmt_interface_setting {
    my $exp=shift;
    my $ipaddr=exists $options{'mgmt_ip'} ? $options{'mgmt_ip'} : $configure{'mgmt'}->{'ipaddr'};
    my $netmask=$configure{'mgmt'}->{'netmask'};
    $ipaddr.="/$netmask";
    my $vlan_id=$configure{'mgmt'}->{'vlan'};
    my $default_route=$configure{'mgmt'}->{'default_route'};
    my @mgmt_interface_cmd;
    unless (exists $vlan_data_current{$vlan_id}){
	die "vlan id $vlan_id not exist on switch\n";
    }
    if ($model=~m/^DES-30/){
	push (@mgmt_interface_cmd, "config ipif System vlan $vlan_data_current{$vlan_id}->{'name'} ipaddress $ipaddr state enable clear_decription");
    }elsif(($model=~m/^DES-32/ and $firmware=~m/^1\./) or $model=~m/^DES-35/){
	push (@mgmt_interface_cmd, "config ipif System vlan $vlan_data_current{$vlan_id}->{'name'} ipaddress $ipaddr state enable");
	push (@mgmt_interface_cmd, "config ipif System dhcp_option12 state disable");
    }elsif($model=~m/^DES-32/ and $firmware=~m/^4\./){
	push (@mgmt_interface_cmd, "config ipif System ipaddress $ipaddr");
	push (@mgmt_interface_cmd, "config ipif System vlan $vlan_data_current{$vlan_id}->{'name'}");
	push (@mgmt_interface_cmd, "config ipif System dhcp_option12 state disable");
    }
    push (@mgmt_interface_cmd, "create iproute default $default_route 1");
    &send_config_cmd_bulk($exp,10,\@mgmt_interface_cmd,$prompt);
}



# convert 1-2,5,6-8 to array (1,2,5,6,7,8)

sub vlan_range_to_array{
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

sub authen_setting{
    my $exp=shift;
    my %authen_protocols=%{$configure{'authen'}};
    my @auth_enable_cmd;
    my $method_list_login_name='login_method';
    my $method_list_enable_name='enable_method';
    my @applications=(
        'console',
        'telnet',
        'ssh',
        'http'
    );

    $exp->send("show authen_login all\n");
    my ($error, $method_list_login_data)=($exp->expect(10,$prompt))[1,3];
    unless ($error eq ''){
        die "Command 'show authen_login all' error: $error";
    }
    $method_list_login_data=~s/[\x0a\x0d]+/\n/g;
    foreach my $line (split("\n",$method_list_login_data)){
	if ($line=~m/^\s*(\w+)\s+\d+\s+.+?\s+.+?/){
	    my $method_name=$1;
	    unless ($method_name eq 'default' or $method_name eq $method_list_login_name){
		push (@auth_enable_cmd, "delete authen_login method_list_name $1");
	    }
	}
    }
    
    $exp->send("show authen_enable all\n");
    my ($error, $method_list_enable_data)=($exp->expect(10,$prompt))[1,3];
    unless ($error eq ''){
        die "Command 'show authen_enable all' error: $error";
    }
    $method_list_enable_data=~s/[\x0a\x0d]+/\n/g;
    foreach my $line (split("\n",$method_list_enable_data)){
	if ($line=~m/^\s*(\w+)\s+\d+\s+.+?\s+.+?/){
	    my $method_name=$1;
	    unless ($method_name eq 'default' or $method_name eq $method_list_enable_name){
		push (@auth_enable_cmd, "delete authen_enable method_list_name $1");
	    }
	}
    }

    $exp->send("show authen server_host\n");
    my ($error, $authen_server_host_data)=($exp->expect(10,$prompt))[1,3];
    unless ($error eq ''){
        die "Command 'show authen server_host' error: $error";
    }
    $authen_server_host_data=~s/[\x0a\x0d]+/\n/g;
    foreach my $line (split("\n",$authen_server_host_data)){
	if ($line=~m/^\s*(.+?)\s+(.+?)\s+(\d+)\s+\d+\s+(?:\d+|No\s+Use|-)\s+(.+?)\s*$/){
	    my $host=$1;
	    my $protocol=$2;
	    $protocol=~tr/A-Z/a-z/;
	    my $port=$3;
	    my $key=$4;
	    #$key=~s/\s+$//;
	    print join("|",$host,$protocol,$port,$key),"|\n";
	    if (exists $authen_protocols{$protocol}->{$host}){
		my $new_port=$authen_protocols{$protocol}->{$host}->{'port'};
		my $new_key=$authen_protocols{$protocol}->{$host}->{'secret_key'};
		if ($new_port ne $port or $new_key ne $key){
		    push (@auth_enable_cmd, "config authen server_host $host protocol $protocol port $new_port key \"$new_key\" timeout 5 retransmit 2");
		}
		delete ($authen_protocols{$protocol}->{$host});
	    }else{
		push (@auth_enable_cmd, "delete authen server_host $host protocol $protocol");
	    }
	}
    }
    
    foreach my $protocol (keys %authen_protocols){
        foreach my $host (keys %{$authen_protocols{$protocol}}){
            my $port=$authen_protocols{$protocol}->{$host}->{'port'};
            my $key=$authen_protocols{$protocol}->{$host}->{'secret_key'};
            push (@auth_enable_cmd, "create authen server_host $host protocol $protocol port $port key \"$key\" timeout 5 retransmit 2");
        }
    }
    push (@auth_enable_cmd, "create authen_login method_list_name $method_list_login_name");
    push (@auth_enable_cmd, "config authen_login method_list_name $method_list_login_name method ".join(" ", keys %authen_protocols)." local");
    push (@auth_enable_cmd, "create authen_enable method_list_name $method_list_enable_name");
    push (@auth_enable_cmd, "config authen_enable method_list_name $method_list_enable_name method ".join(" ", keys %authen_protocols)." local_enable");
    foreach my $app (@applications){
        push (@auth_enable_cmd, "config authen application $app login method_list_name $method_list_login_name");
        push (@auth_enable_cmd, "config authen application $app enable method_list_name $method_list_enable_name");
    }
    push (@auth_enable_cmd,
        (
        'config authen parameter response_timeout 0',
        'config authen parameter attempt 3',
        'disable authen_policy',
        'config authen enable_admin none state enable',
        'config authen enable_admin radius state enable',
        'config authen enable_admin tacacs state enable',
        'config authen enable_admin tacacs+ state enable',
        'config authen enable_admin xtacacs state enable',
        'config authen enable_admin local state enable'
        )
    );
    &send_config_cmd_bulk($exp,10,\@auth_enable_cmd,$prompt);
}

sub send_config_cmd {
    my $exp=shift;
    my $timeout=shift;
    my $cmd=shift;
    my $prompt=shift;
    
    $exp->send("$cmd\n");
    my ($error, $output)=($exp->expect($timeout, $prompt))[1,3];
    unless ($error eq ''){
	die "'$cmd' not set error: $error";
    }else{
	my ($error, $result);
	$output=~s/[\x0a\x0d]+/\n/g;
	my @output=split("\n",$output);
	$result=$output[$#output];
	$result=~s/^\s+//;
	$result=~s/\s+$//;
	if ($result eq 'Fail'){
	    $error=join(" ", @output[2..$#output-1]) ;
	    print "Error command: '$cmd'\n";
	    print "Error message: $error\n\n";
	}
    }
}

sub send_config_cmd_bulk {
    my $exp=shift;
    my $timeout=shift;
    my $cmd_ref=shift;
    my $prompt=shift;
    foreach my $cmd (@$cmd_ref){
	unless(exists $current_switch_config{$cmd}){
	    &send_config_cmd($exp,$timeout,$cmd,$prompt);
	    $current_switch_config{$cmd}=1;
	}
    }
}

sub read_config{
    my $exp=shift;
    my %config;
    my $vendor='D-LINK';
    my $model;
    my $firmware;
    $exp->send("show config current_config\n");
    my $config_tmp;
    my ($error, $config)=($exp->expect(undef,
	['Next Entry', sub {	my $self = shift;
				$config_tmp=$self->before;
				$self->send("a\n");
				exp_continue; }],
	$prompt
    ))[1,3];
    unless ($error eq ''){
        die "Command 'show config current_config' error: $error";
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
    return (\%config, $vendor, $model, $firmware);
}



sub connect_to_switch{

    my $exp;
    if ($connect_type eq 'console'){
	$exp=&console_connect($dev_name, $line_speed);
    }elsif($connect_type eq 'telnet'){
	$exp=&telnet_connect($switch_ip);
    }elsif($connect_type eq 'ssh'){
	$exp=&ssh_connect($switch_ip, $username);
    }else{
	die "Not support connect type: $connect_type";
    }
    
    my ($error, $prompt)=($exp->expect(10,
	[ 'Are you sure you want to continue connecting', 
			sub {	my $self = shift;
	                        $self->send("yes\n");
	                        exp_continue; }],
	[ qr/username:/i, sub {	my $self = shift;
				$self->send("$username\n");
	                    	exp_continue; }],
	[ qr/password:/i, sub { my $self = shift;
	                        $self->send("$password\n");
	    	                exp_continue; }],
	'#'
    ))[1,3];
    unless ($error eq ''){
        die "Can't connect to switch, error: $error";
    }
    $prompt=~s/[\x0a\x0d]+/\n/g;
    my @prompt=split("\n", $prompt);
    $prompt=$prompt[$#prompt].'#';
    return ($exp, $prompt);
}

sub telnet_connect {

    my $switch_ip=shift;
    my ($error, $port);
    ($switch_ip,$port)=split(':',$switch_ip);
    $port=23 unless ($port=~m/\d+/);

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

    $exp->log_stdout(0) unless ($enable_stdout);

    return $exp;
}

sub ssh_connect {

    my $switch_ip=shift;
    my $user_name=shift;
    my ($error,$port);
    ($switch_ip,$port)=split(':',$switch_ip);
    $port=22 unless ($port=~m/\d+/);

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

    $exp->log_stdout(0) unless ($enable_stdout);

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

	$exp->log_stdout(0) unless ($enable_stdout);
	    
	$error=($exp->expect(10,'Connected'))[1];
	    
	unless ($error eq ''){
		die "Can't connect to console, error: $error";
	}else{
	    $exp->send("\n");
	}
    }elsif ($basename eq 'screen'){
	if (! ($exp=Expect->spawn("$console_cmd -S scm_connect $dev $speed"))){
	    $error="can't spawn $console_cmd $dev $speed";
	    die $error;
	}

	$exp->log_stdout(0) unless ($enable_stdout);
	$exp->send("\n");
    }
    else{
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

sub check_config {
    my $conf_file=shift;
    my $conf=Config::General->new($conf_file);
    my %config=$conf->getall;
    my $error_flag=0;

    if (exists $config{'account'}){
        foreach my $user (keys %{$config{'account'}->{'user'}}){
            if (
                not exists $config{'account'}->{'user'}->{$user}->{'access_level'}
                or $config{'account'}->{'user'}->{$user}->{'access_level'} eq ''
                )
                {
                    $config{'account'}->{'user'}->{$user}->{'access_level'}='admin';
                }
            unless ($config{'account'}->{'user'}->{$user}->{'access_level'}=~m/^(admin|user)$/){
                print "Config file '$conf_file' error: user $user access_level must be 'admin' or 'user'\n";
                $error_flag=1;
            }
            if ($config{'account'}->{'user'}->{$user}->{'password'} eq ''){
                print "Config file '$conf_file' error: user $user password must be set\n";
                $error_flag=1;
            }
        }
    }
    if (exists $config{'enable'}){
	unless (exists $config{'enable'}->{'old_enable_password'}){
	    $config{'enable'}->{'old_enable_password'}='';
	}
	unless (exists $config{'enable'}->{'enable_password'}){
	    print "Config file '$conf_file' error: enable_password must be set\n";
	    $error_flag=1;
	}
    }
    if (exists $config{'telnet'}){
        unless ($config{'telnet'}->{'telnet_enable'}=~m/^[01]$/){
            print "Config file '$conf_file' error: telnet_enable must be '0' or '1'\n";
            $error_flag=1;
        }
    }
    if (exists $config{'ssh'}){
        unless ($config{'ssh'}->{'ssh_enable'}=~m/^[01]$/){
            print "Config file '$conf_file' error: ssh_enable must be '0' or '1'\n";
            $error_flag=1;
        }
    }
    if (exists $config{'web'}){
        unless ($config{'web'}->{'web_enable'}=~m/^[01]$/){
            print "Config file '$conf_file' error: web_enable must be '0' or '1'\n";
            $error_flag=1;
        }
        unless (exists $config{'web'}->{'ssl_prefer'}){
            $config{'web'}->{'ssl_prefer'}=1;
        }
        unless ($config{'web'}->{'ssl_prefer'}=~m/^[01]$/){
            print "Config file '$conf_file' error: ssl_prefer must be '0' or '1'\n";
            $error_flag=1;
        }
    }
    if (exists $config{'snmp'}){
        if ($config{'snmp'}->{'ro_comm'} eq ''){
            print "Config file '$conf_file' error: ro_comm must be set\n";
            $error_flag=1;
        }
        if ($config{'snmp'}->{'rw_comm'} eq ''){
            print "Config file '$conf_file' error: rw_comm must be set\n";
            $error_flag=1;
        }
    }
    if (exists $config{'vlans'}){
        my %vlan_names;
        my %untagged_vlans;
        foreach my $vlan_id (keys %{$config{'vlans'}->{'vlan'}}){
            unless ($vlan_id=~m/^\d+$/){
                print "Config file '$conf_file' error: Vlan id must be number\n";
                $error_flag=1;
            }
            if ($config{'vlans'}->{'vlan'}->{$vlan_id}->{'name'} eq ''){
                print "Config file '$conf_file' error: Vlan name must be set\n";
                $error_flag=1;
            }
            if (exists $vlan_names{$config{'vlans'}->{'vlan'}->{$vlan_id}->{'name'}}){
                print "Config file '$conf_file' error: Vlan name '$config{'vlans'}->{'vlan'}->{$vlan_id}->{'name'}' must be unique\n";
                $error_flag=1;
            }else{
                $vlan_names{$config{'vlans'}->{'vlan'}->{$vlan_id}->{'name'}}=1;
            }

            if (exists $config{'vlans'}->{'vlan'}->{$vlan_id}->{'tagged_ports'}){
                foreach my $tagged_port (split(",",$config{'vlans'}->{'vlan'}->{$vlan_id}->{'tagged_ports'})){
                    $tagged_port=~s/\s+//g;
                    unless ($tagged_port=~/^\d+$/){
                        print "Config file '$conf_file' error: Port '$tagged_port' must be number\n";
                        $error_flag=1;
                        next;
                    }
                    $config{'vlans'}->{'vlan'}->{$vlan_id}->{'ports'}->{$tagged_port}=TAGGED_PORT;
                }
            }
            if (exists $config{'vlans'}->{'vlan'}->{$vlan_id}->{'untagged_ports'}){
                foreach my $untagged_port (split(",",$config{'vlans'}->{'vlan'}->{$vlan_id}->{'untagged_ports'})){
                    $untagged_port=~s/\s+//g;
                    unless ($untagged_port=~/^\d+$/){
                        print "Config file '$conf_file' error: Port '$untagged_port' must be number\n";
                        $error_flag=1;
                        next;
                    }
                    if (exists $config{'vlans'}->{'vlan'}->{$vlan_id}->{'ports'}->{$untagged_port}){
                        print "Config file '$conf_file' error: Port '$untagged_port' in vlan $vlan_id is tagged and untagged at the same time\n";
                        $error_flag=1;
                        next;
                    }else{
                        if (exists $untagged_vlans{$untagged_port}){
                            print "Config file '$conf_file' error: Port '$untagged_port' is untagged on several vlan\n";
                            $error_flag=1;
                            next;
                        }else{
                            $untagged_vlans{$untagged_port}=$vlan_id;
                        }
                        $config{'vlans'}->{'vlan'}->{$vlan_id}->{'ports'}->{$untagged_port}=UNTAGGED_PORT;
                    }
                }
            }
        }
    }

    if (exists $config{'console'}){
	my %support_speed=(
	    9600 => 1,
	    19200 => 1,
	    38400 => 1,
	    115200 => 1
	);
	my %support_auto_logout=(
	    2 => 1,
	    5 => 1,
	    10 => 1,
	    15 => 1
	);
	unless (exists $support_speed{$config{'console'}->{'speed'}}){
            print "Config file '$conf_file' error: console speed must be 9600 | 19200 | 38400 | 115200\n";
            $error_flag=1;
        }
        unless (exists $support_auto_logout{$config{'console'}->{'auto_logout'}}){
            print "Config file '$conf_file' error: console auto_logout must be 2 | 5| 10 | 15\n";
            $error_flag=1;
        }
    }

    if (exists $config{'mgmt'}){
	if (exists $config{'mgmt'}->{'ipaddr'}){
	    unless ($config{'mgmt'}->{'ipaddr'}=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/){
		print "Config file '$conf_file' error: Uncorrected ip/mask '$config{'mgmt'}->{'ipaddr'}'\n";
		$error_flag=1;
	    }
	}
	unless ($config{'mgmt'}->{'netmask'}=~m/^(?:[012]?[0-9]|3[0-2])$/){
	    print "Config file '$conf_file' error: Uncorrected netmask '$config{'mgmt'}->{'netmask'}'\n";
	    $error_flag=1;
	}
	unless ($config{'mgmt'}->{'vlan_id'}=~m/^\d+$/){
	    print "Config file '$conf_file' error: Uncorrected vlan id '$config{'mgmt'}->{'vlan_id'}'\n";
	    $error_flag=1;
	}
	unless ($config{'mgmt'}->{'default_route'}=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/){
	    print "Config file '$conf_file' error: Uncorrected default route '$config{'mgmt'}->{'default_route'}'\n";
	    $error_flag=1;
	}
    }

    if (exists $config{'authen'}){
        my %protocol_host;
        foreach my $auth_protocol (keys %{$config{'authen'}}){
            unless ($auth_protocol=~m/^(radius|tacacs|tacacs\+|xtacacs)$/){
                print "Config file '$conf_file' error: Unsupported auth protocol '$auth_protocol'\n";
                $error_flag=1;
            }
            foreach my $host (keys %{$config{'authen'}->{$auth_protocol}}){
                unless ($host=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/){
                    print "Config file '$conf_file' error: Uncorrected ip '$host'\n";
                    $error_flag=1;
                    next;
                }
                unless (exists $config{'authen'}->{$auth_protocol}->{$host}->{'port'}){
                    if ($auth_protocol eq 'radius'){
                        $config{'authen'}->{$auth_protocol}->{$host}->{'port'}=1812;
                    }elsif($auth_protocol=~m/^(tacacs|tacacs\+|xtacacs)$/){
                        $config{'authen'}->{$auth_protocol}->{$host}->{'port'}=49;
                    }
                }
                unless ($config{'authen'}->{$auth_protocol}->{$host}->{'port'}=~m/^\d+$/){
                    print "Config file '$conf_file' error: Wrong port number '$config{'authen'}->{$auth_protocol}->{$host}->{'port'}'\n";
                    $error_flag=1;
                    next;
                }
                if (exists $protocol_host{$auth_protocol}->{$host}){
                    print "Config file '$conf_file' error: The same ip '$host' on same protocol $auth_protocol\n";
                    $error_flag=1;
                }else{
                    $protocol_host{$auth_protocol}->{$host}=1;
                }
            }
        }
    }
    die if $error_flag;
    return %config;
}

sub read_options {
    my %options=();
    my %return_options;
    getopts("s:t:c:l:u:p:i:", \%options);
    if (exists $options{'u'} and exists $options{'p'}){
        if (exists $options{'s'}){
            unless ($options{'s'}=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/){
                &help();
                exit;
            }else{
                $return_options{'connect_type'}='ssh';
                $return_options{'switch_ip'}=$options{'s'};
                $return_options{'user_name'}=$options{'u'};
                $return_options{'password'}=$options{'p'};
            }
        }elsif (exists $options{'t'}){
            unless ($options{'t'}=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/){
                &help();
                exit;
            }else{
                $return_options{'connect_type'}='telnet';
                $return_options{'switch_ip'}=$options{'t'};
                $return_options{'user_name'}=$options{'u'};
                $return_options{'password'}=$options{'p'};
            }
        }elsif(exists $options{'c'} and exists $options{'l'}){
            unless ($options{'l'}=~m/^\d+$/){
                &help();
                exit;
            }
            $return_options{'connect_type'}='console';
            $return_options{'dev_name'}=$options{'c'};
            $return_options{'line_speed'}=$options{'l'};
            $return_options{'user_name'}=$options{'u'};
            $return_options{'password'}=$options{'p'};
        }else{
            &help();
            exit;
        }
        
        if (exists $options{'i'}){
	    if ($options{'i'}=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/){
		$return_options{'mgmt_ip'}=$options{'i'};
	    }else{
		&help();
        	exit;
	    }
	}
    }else{
        &help();
        exit;
    }
    return %return_options;
}

sub help {
    print "Usage for ssh connect:\t\t$0 -s switch_ip[:port] -u user_name -p password\n";
    print "Usage for telnet connect:\t$0 -t switch_ip[:port] -u user_name -p password\n";
    print "Usage for console connect:\t$0 -c dev_name -l line_speed -u user_name -p password -i mgmt_ip\n";
}

sub kill_screen {
    my $basename=$console_cmd;
    $basename=~s/.*\///;
    if ($basename eq 'screen' and $connect_type eq 'console'){
	foreach my $line (split("\n",`$console_cmd -ls`)){
	    if ($line=~m/(\d+\.scm_connect)/){
		`$console_cmd -S "$1" -X quit`;
	    }
	}
    }
}

END {
    &kill_screen();
}