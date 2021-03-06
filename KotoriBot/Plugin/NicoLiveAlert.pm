# 文字コードはＵＴＦ－８、改行コードはＬＦのみ
# $Id$

package KotoriBot::Plugin::NicoLiveAlert;

use strict;
use warnings;
use utf8;

use KotoriBot::Plugin;

our @ISA = qw(KotoriBot::Plugin);

my $receiver;

sub initialize {
	my($self) = @_;

	$self->{communities} = {};
	my $communitiesref = $self->{args}->{communities};
	if ($communitiesref) {
		my @communities = @$communitiesref;
		foreach my $community (@communities) {
			$self->{communities}->{$community} = 1;
		}
	}

	$receiver = KotoriBot::Plugin::NicoLiveAlert::Receiver->new() unless defined($receiver);
	$receiver->add($self);
}

sub destroy {
	my($self) = @_;

	$receiver->remove($self);
}

sub notice {
	my($self, $message) = @_;

	$self->{channel}->notice($message);
}

sub need_notice {
	my($self, $community) = @_;

#	return $community =~ /[123]0/;
	return exists($self->{communities}->{$community});
}

###############################################################################

package KotoriBot::Plugin::NicoLiveAlert::Receiver;

use strict;
use warnings;
use utf8;

use HTTP::Request::Common;
use POE qw(Component::Client::HTTP Component::Client::TCP);
use XML::DOM;
use XML::DOM::XPath;

my $retry_interval = 60;
my $tick_interval = 90;

sub new {
	my($class) = @_;

	my $self = bless({
		plugins => [],
		last => undef,
		alertlist => {},
	}, $class);

	$self->{ua_alias} = "$self-POE::Component::Client::HTTP";
	POE::Component::Client::HTTP->spawn(
		Alias => $self->{ua_alias},
		Agent => KotoriBot::Core->agent(),
	);

	$self->{tcp_alias} = "$self-POE::Component::Client::TCP";

	my $session = POE::Session->create(
		object_states => [
			$self => [ qw(
				_start tick begin done_auth do_notice
				tcp_connect tcp_connect_error tcp_disconnect tcp_server_input tcp_server_error
			) ],
		],
		heap => {}
	);
	$self->{session} = $session;

	return $self;
}

sub _start {
	my($self) = @_;

	$self->{lastrecv} = 0;

	POE::Kernel->delay("tick", $tick_interval);

	POE::Kernel->delay("begin", 5);
}

sub tick {
	my($self) = @_;

	POE::Kernel->delay("tick", $tick_interval);

	if ($self->{tcpheap} && $self->{tcpheap}->{connected}) {
		if ($self->{lastrecv} < time() - $tick_interval) {
			POE::Kernel->call($self->{tcp_alias}, "shutdown");
			POE::Kernel->delay("begin", 0); # ここは $retry_interval ではなく即座
		}
	}
}

sub begin {
	my($self) = @_;

	$self->{tcpheap} = undef;

	my $req = HTTP::Request::Common::GET("http://live.nicovideo.jp/api/getalertinfo");
	POE::Kernel->post($self->{ua_alias}, "request", "done_auth", $req);
}

sub done_auth {
	my($self, $reqp, $resp) = @_[OBJECT, ARG0, ARG1];

	my $res = $resp->[0];

	if (!$res->is_success) {
		POE::Kernel->delay("begin", $retry_interval);
		return;
	}

	my $parser = XML::DOM::Parser->new();
	my $doc = $parser->parse($res->content);

	my $docel = findnode($doc, '//getalertstatus');
	if (!defined($docel) || $docel->getAttribute("status") ne "ok") {
		POE::Kernel->delay("begin", $retry_interval);
		return;
	}

	my $host = findnode($doc, '//addr/text()')->getData();
	my $port = findnode($doc, '//port/text()')->getData();
	my $thread = findnode($doc, '//thread/text()')->getData();

	$self->{thread} = $thread;

	my $session = $self->{session};

	POE::Component::Client::TCP->new(
		RemoteAddress  => $host,
		RemotePort     => $port,
		Alias          => $self->{tcp_alias},
		Filter         => POE::Filter::Line->new(Literal => "\0"),
		# 親セッションにイベントを投げてくれるわけではないので自力で投げる
		Connected      => sub { $self->{tcpheap} = $_[HEAP]; POE::Kernel->call($session, "tcp_connect", @_[ARG0, ARG1, ARG2]) },
		ConnectError   => sub { POE::Kernel->call($session, "tcp_connect_error", @_[ARG0, ARG1, ARG2]) },
		Disconnected   => sub { POE::Kernel->call($session, "tcp_disconnect") },
		ServerInput    => sub { POE::Kernel->call($session, "tcp_server_input", $_[ARG0]) },
		ServerError    => sub { POE::Kernel->call($session, "tcp_server_error", @_[ARG0, ARG1, ARG2]) },
	);
}

sub tcp_connect {
	my($self, $sock, $addr, $port) = @_[OBJECT, ARG0, ARG1, ARG2];

	$self->{tcpheap}->{server}->put("<thread thread=\"$self->{thread}\" res_from=\"-1\" version=\"20061206\"/>\0");
}

sub tcp_connect_error {
	POE::Kernel->delay("begin", $retry_interval);
}

sub tcp_disconnect {
	POE::Kernel->delay("begin", $retry_interval);
}

sub tcp_server_input {
	my($self, $data) = @_[OBJECT, ARG0];

	$self->{lastrecv} = time();

	print "$data\n";
	# ニコ生の場合は、
	#  <chat date="1279341286" no="4742981" premium="6" thread="1000000013" user_id="394">21746141,co394703,12607237</chat>
	# のようなレコードが来る。
	# ニコ実況の場合は、
	#  <chat date="1279341285" no="4742980" premium="6" thread="1000000013" user_id="394">jk7895,co370317,1445265</chat>
	# のようなレコードが来る。
	if ($data =~ m|^<chat\s.*?>(.+?)</chat>$| && $1 =~ /^(\d+|jk\d+),((?:ch|co)\d+),(\d+)$/) {
		my $liveid = $1;
		my $community = $2;
		my $userid = $3;
		my $need_notice = 0;
		foreach my $plugin (@{$self->{plugins}}) {
			$need_notice |= $plugin->need_notice($community);
		}
		if ($need_notice) {
			if (!$self->{alertlist}->{$liveid}) {
				$self->{alertlist}->{$liveid} = 1;
				if ($liveid =~ /^\d+$/) {
					my $req = HTTP::Request::Common::GET(
							"http://live.nicovideo.jp/api/getstreaminfo/lv$liveid"
					);
					POE::Kernel->post($self->{ua_alias}, "request", "do_notice", $req, ["lv$liveid", $community]);
				} elsif ($liveid =~ /^jk\d+$/) {
					# ニコ実況の情報を取得するAPIは今のところ不明
					$self->notice($community, "NicoLiveAlert: http://jk.nicovideo.jp/watch/$liveid ($community)");
				}
			}
		}
	}
}

sub tcp_server_error {
	POE::Kernel->delay("begin", $retry_interval);
}

sub do_notice {
	my($self, $reqp, $resp) = @_[OBJECT, ARG0, ARG1];

	my $res = $resp->[0];
	my $liveid = $reqp->[1]->[0];
	my $community = $reqp->[1]->[1];

	if (!$res->is_success) {
		$self->notice($community, "NicoLiveAlert: http://live.nicovideo.jp/watch/$liveid ($community)");
		return;
	}

	my $parser = XML::DOM::Parser->new();
	my $doc = $parser->parse($res->content);

	my $docel = findnode($doc, '//getstreaminfo');
	if (!defined($docel) || $docel->getAttribute("status") ne "ok") {
		$self->notice($community, "NicoLiveAlert: http://live.nicovideo.jp/watch/$liveid ($community)");
		return;
	}

	# タイトルやコミュ名は長い場合に切られて送られてくるようだ。
	my $title = findnode($doc, '//title/text()')->getData();
	my $comname = findnode($doc, '//communityinfo/name/text()')->getData();

	$self->notice($community, "NicoLiveAlert: http://live.nicovideo.jp/watch/$liveid $title ($community $comname)");
}

sub notice {
	my($self, $community, $message) = @_;

	foreach my $plugin (@{$self->{plugins}}) {
		$plugin->notice($message) if ($plugin->need_notice($community));
	}
}

sub add {
	my($self, $plugin) = @_;

	push(@{$self->{plugins}}, $plugin);
}

sub remove {
	my($self, $plugin) = @_;

	@{$self->{plugins}} = grep { $_ != $plugin } @{$self->{plugins}};
}

sub findnode($$) {
	my($doc, $path) = @_;

	my @nodes = $doc->findnodes($path);
	return $nodes[0];
}

###############################################################################

return 1;
