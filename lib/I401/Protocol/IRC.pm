package I401::Protocol::IRC;
use strict;
use warnings;
use Web::Encoding;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw(decode_ctcp);

sub new_from_i401_and_config_and_logger ($$$) {
  return bless {i401 => $_[1], config => $_[2], logger => $_[3]}, $_[0];
} # new

sub config ($) {
  return $_[0]->{config};
} # config

sub log ($$;%) {
  my ($self, $text, %args) = @_;
  $self->{logger}->($text);
} # log

sub client {
    my $self = $_[0];
    $self->{client} ||= do {
        my $client = AnyEvent::IRC::Client->new;
        my $config = $self->config;
        if ($config->{tls}) {
          $client->enable_ssl;
        } else {
          $self->log ('Warning: TLS is disabled; this connection is unsafe!');
        }

        $client->set_nick_change_cb(sub {
            my $nick = shift;
            if ($nick =~ /\A(.*[^0-9]|)401\z/s) {
                return $1.400;
            } elsif ($nick =~ /\A(.*[^0-9]|)([0-9]+)\z/s) {
                return $1.($2+1);
            } else {
                return $nick.2;
            }
        });

        $self->log('Connect...');
        $client->reg_cb(connect => sub {
            my ($client, $err) = @_;
            $self->log("Connected");
            die $err if defined $err;
        });
        $client->reg_cb(registered => sub {
            $self->log('Registered');
            $client->send_srv(JOIN => encode_web_utf8 $_)
                for @{$config->{default_channels} or []};
            $client->enable_ping (60);
        });

        $client->reg_cb(disconnect => sub {
            $self->log('Disconnected', class => 'error');
            undef $client;
            if ($self->{shutdown}) {
              (delete $self->{onshutdown})->() if $self->{onshutdown};
            } else {
              $self->reconnect;
            }
        });

        $client->connect(
            scalar ($config->{hostname} || die "No |hostname|"),
            scalar ($config->{port} || 6667),
            {
                nick => ($config->{nick} || die "No |nick|"),
                real => $config->{real},
                user => $config->{user},
                password => $config->{password},
                timeout => 10,
            },
        );

        $self->{timer} = AE::timer 60, 0, sub {
            unless ($client and $client->registered) {
                $self->log("Timeout", class => 'error');
                $client->disconnect if $client;
                $self->reconnect;
            }
            undef $self->{timer};
        };

        $client->reg_cb(irc_invite => sub {
            my ($client, $msg) = @_;
            my $channel = $msg->{params}->[1]; # no decode
            $client->send_srv(JOIN => $channel); # no encode
        });

        $client->reg_cb(join => sub {
            my ($client, $nick, $channel, $is_myself) = @_;
            if ($is_myself) {
                $channel = decode_web_utf8 $channel;
                $self->log('Join ' . $channel);
                $self->{current_channels}->{$channel}++;
            }
        });

        $client->reg_cb (kick => sub {
            my ($client, $kicked_nick, $channel, $is_myself, $msg, $kicker_nick) = @_;
            if ($client->is_my_nick ($kicked_nick)) { # $is_myself is wrong
                $self->log ("Kicked by $kicker_nick ($msg)");
                my $timer; $timer = AE::timer 10, 0, sub {
                    $self->client->send_srv(JOIN => encode_web_utf8 $channel)
                        unless $self->{current_channels}->{$channel};
                    undef $timer;
                };
            }
        });

        $client->reg_cb(channel_remove => sub {
            my ($client, $msg, $channel, @nick) = @_;
            if (grep { $client->is_my_nick($_) } @nick) {
                $channel = decode_web_utf8 $channel;
                $self->log('Part ' . $channel);
                delete $self->{current_channels}->{$channel};
            }
        });

        $client->reg_cb(irc_privmsg => sub {
            my (undef, $msg) = @_;
            my ($trail, $ctcp) = decode_ctcp($msg->{params}->[-1]);
            my $channel = decode_web_utf8 $msg->{params}->[0];
            $msg->{params}->[-1] = $trail;

            if ($msg->{params}->[-1] ne '') {
                my $nick = [split /!/, $msg->{prefix}, 2]->[0];
                unless ($client->is_my_nick($nick)) {
                    my $charset = $self->get_channel_charset($channel);
                    my $text = decode_web_charset $charset, $msg->{params}->[-1];
                    $self->{i401}->process_by_rules({
                        prefix => $msg->{prefix},
                        channel => $channel,
                        command => $msg->{command},
                        text => $text,
                    });
                }
            }
        });
        $client->reg_cb(irc_notice => sub {
            my (undef, $msg) = @_;
            my ($trail, $ctcp) = decode_ctcp($msg->{params}->[-1]);
            my $channel = decode_web_utf8 $msg->{params}->[0];
            $msg->{params}->[-1] = $trail;

            if ($msg->{params}->[-1] ne '') {
                my $nick = [split /!/, $msg->{prefix}, 2]->[0];
                unless ($client->is_my_nick($nick)) {
                    my $charset = $self->get_channel_charset($channel);
                    my $text = decode_web_charset $charset, $msg->{params}->[-1];
                    $self->{i401}->process_by_rules({
                        prefix => $msg->{prefix},
                        channel => $channel,
                        command => $msg->{command},
                        text => $text,
                    });
                }
            }
        });

        $client;
    };
}

sub connect ($) {
  $_[0]->client;
} # connect

sub set_shutdown_mode ($$) {
  $_[0]->{shutdown} = 1;
  $_[0]->{onshutdown} = $_[1];
} # set_shutdown_mode

sub disconnect ($) {
  my $self = shift;
  delete $self->{current_channels};
  if ($self->{client}) {
    $self->client->disconnect;
    delete $self->{client};
  } else {
    if ($self->{shutdown}) {
      (delete $self->{onshutdown})->() if $self->{onshutdown};
    }
  }
} # disconnect

sub reconnect {
    my $self = shift;
    delete $self->{client};
    delete $self->{current_channels};
    my $timer; $timer = AE::timer 10, 0, sub {
        $self->connect;
        undef $timer;
    };
}

sub get_channel_charset {
    my ($self, $channel) = @_;
    return $self->config->{channel_charset}->{$channel} ||
           $self->config->{charset} ||
           'utf-8';
}

sub get_channel_users {
    my ($self, $channel) = @_;
    my $client = $self->client;
    my $user_mode = ($client->{channel_list}->{encode_web_utf8 $client->lower_case($channel)} || {});
    return [ grep { not $client->is_my_nick($_) } keys %$user_mode ];
}

sub send_notice ($$$) {
  my ($self, $channel, $text) = @_;
  $text =~ s/\A[\x0D\x0A]+//;
  $text =~ s/[\x0D\x0A]+\z//;
  for my $text (split /\x0D?\x0A/, $text) {
    $self->client->send_srv(JOIN => encode_web_utf8 $channel)
        unless $self->{current_channels}->{$channel};
    my $charset = $self->get_channel_charset($channel);
    my $max = $self->config->{max_length} || 200;
      while (length $text) {
        my $t = substr ($text, 0, $max);
        substr ($text, 0, $max) = '';
        $self->client->send_srv('NOTICE',
                                (encode_web_utf8 $channel),
                                (encode_web_charset $charset, $t));
      }
  }
} # send_notice

sub send_privmsg ($$$) {
  my ($self, $channel, $text) = @_;
  $text =~ s/\A[\x0D\x0A]+//;
  $text =~ s/[\x0D\x0A]+\z//;
  for my $text (split /\x0D?\x0A/, $text) {
    $self->client->send_srv(JOIN => encode_web_utf8 $channel)
        unless $self->{current_channels}->{$channel};
    my $charset = $self->get_channel_charset($channel);
    my $max = $self->config->{max_length} || 200;
    while (length $text) {
      my $t = substr ($text, 0, $max);
      substr ($text, 0, $max) = '';
      $self->client->send_srv('PRIVMSG',
                              (encode_web_utf8 $channel),
                              (encode_web_charset $charset, $t));
    }
  }
} # send_privmsg

1;
