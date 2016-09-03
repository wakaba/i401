package I401::Main;
use strict;
use warnings;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::HTTPD;
use Web::Encoding;
use I401::Protocol::IRC;

sub new_from_config ($$) {
  return bless {config => $_[1]}, $_[0];
} # new_from_config

sub config {
    return $_[0]->{config};
}

sub _set_protocol ($) {
  my ($self) = @_;
  return $self->{protocol} = I401::Protocol::IRC->new_from_i401_and_config_and_logger
      ($self, $self->config, $self->logger);
} # _set_protocol

sub protocol ($) {
  return $_[0]->{protocol};
} # protocol

sub connect ($) {
  return $_[0]->protocol->connect;
} # connect

sub disconnect ($) {
  return $_[0]->protocol->disconnect;
} # disconnect

sub register_rules {
    my $self = shift;
    push @{$self->{rules} ||= []}, @_;
}

sub process_by_rules {
    my ($self, $args) = @_;
    for (@{$self->{rules} ||= []}) {
        if ($_->{privmsg} and $_->{notice}) {
            next unless $args->{command} eq 'PRIVMSG' or
                        $args->{command} eq 'NOTICE';
        } elsif ($_->{privmsg}) {
            next unless $args->{command} eq 'PRIVMSG';
        } elsif ($_->{notice}) {
            next unless $args->{command} eq 'NOTICE';
        }

        my $pattern = defined $_->{pattern} ? $_->{pattern} : qr/(?:)/;
        next       unless $args->{text} =~ /$pattern/;
        $_->{code}->($self, $args); ## $1... of ^ available from |code|
    }
}

sub send_notice ($$$) {
  return $_[0]->protocol->send_notice ($_[1], $_[2]);
} # send_notice

sub send_privmsg ($$$) {
  return $_[0]->protocol->send_privmsg ($_[1], $_[2]);
} # send_privmsg

sub listen {
    my $self = shift;
    return unless $self->config->{http_port};

    $self->{httpd} = AnyEvent::HTTPD->new (
        hostname => $self->config->{http_hostname},
        port => $self->config->{http_port},
    );
    $self->log(sprintf 'Listening %s:%d...',
                   $self->config->{http_hostname},
                   $self->config->{http_port});

    $self->{httpd}->reg_cb (
        '' => sub {
            my ($httpd, $req) = @_;
            $self->log(sprintf '%s %s %s', $req->client_host, $req->method, $req->url);
            my $path = $req->url->path;
            unless ($path =~ m{\A/(notice|privmsg)\z}) {
                return $req->respond([400, 'Not found', {}, '404 Not found']);
            }
            my $method = 'send_' . $1;
            my $command = uc $1;

            return $req->respond([405, 'Method not allowed', {Allow => 'POST'},
                                  '405 Method not allowed'])
                unless $req->method eq 'POST';
            return $req->respond([400, 'Access from browser not allowed', {},
                                  '400 Access from browser not allowed'])
                if defined $req->headers->{origin};

            my $channel = $req->parm('channel');
            my $msg = $req->parm('message');
            my $apply_rules = $req->parm('rules');

            $req->respond([400, 'Bad channel', {}, '400 Bad channel'])
                unless defined $channel and length $channel;
            $req->respond([400, 'Bad message', {}, '400 Bad message'])
                unless defined $msg and length $msg;

            $channel = decode_web_utf8 $channel;
            $msg = decode_web_utf8 $msg;

            AE::postpone {
                $self->$method($channel, $msg);

                $self->process_by_rules({
                    prefix => '!',
                    channel => $channel,
                    command => (($apply_rules and $apply_rules eq 'PRIVMSG')
                                    ? 'PRIVMSG' : $command),
                    text => $msg,
                }) if $apply_rules;
            };
            $req->respond([202, 'Accepted', {}, '202 Accepted']);
        },
    );
}

sub run_as_cv ($) {
  my $self = shift;
  my $cv = AE::cv;

  $self->_set_protocol;
  $self->connect;
  $self->listen;

  my $shutdown = sub {
    delete $self->{protocol};
    $cv->send;
  };

  $self->{sigterm} = AE::signal TERM => sub {
    $self->log('SIGTERM received', class => 'error');
    $self->protocol->set_shutdown_mode ($shutdown);
    $self->disconnect;
    delete $self->{sigterm};
    delete $self->{sigint};
  };
  $self->{sigint} = AE::signal INT => sub {
    $self->log('SIGINT received', class => 'error');
    $self->protocol->set_shutdown_mode ($shutdown);
    $self->disconnect;
    delete $self->{sigterm};
    delete $self->{sigint};
  };

  return $cv;
} # run_as_cv

sub run ($) {
  my $cv = $_[0]->run_as_cv;
  $cv->recv;
} # run

sub stderr {
    return $_[0]->{stderr} ||= do {
        my $handle = AnyEvent::Handle->new(
            fh => \*STDERR,
            on_error => sub {
                my ($hdl, $fatal, $msg) = @_;
                AE::log error => $msg;
                $hdl->destroy;
                #$cv->send;
            },
        );
        $handle;
    };
}

sub logger ($) {
  my $self = $_[0];
  my $stderr = $self->stderr;
  my $name = $self->config->{name};
  $name = defined $name ? "$name " : '';
  return sub {
    $stderr->push_write
        (encode_web_utf8 ('[' . (gmtime) . '] ' . $name . $_[0] . "\n"));
  };
} # logger

sub log ($$;%) {
  my ($self, $text, %args) = @_;
  $self->logger->($text);
} # log

1;
