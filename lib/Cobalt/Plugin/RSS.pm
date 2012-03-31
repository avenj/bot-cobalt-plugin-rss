package Cobalt::Plugin::RSS;
our $VERSION = '0.01';

use POE qw/Component::RSSAggregator/;
use Cobalt::Common;
use File::Spec;

sub new { bless {}, shift }
sub core { 
  my ($self, $core) = @_;
  return $self->{CORE} = $core if $core and ref $core;
  return $self->{CORE}
}

sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;
  $self->core($core);
  
  $self->{FEEDS} = {};

  $core->log->debug("Spawning session to handle RSS");
  POE::Session->create(
    object_states => [
      $self => [
        '_start',
        '_feed',
      ],
    ],
  );
  
  my $pcfg = $core->get_plugin_cfg($self);

  ## pre-configured feeds:
  ##   Name: URL
  my $preconf = $pcfg->{Feeds};
  if ($preconf && ref $preconf eq 'HASH') {
    for my $feedname (keys %$preconf) {
      my $uri = $preconf->{$feedname};
      $self->{FEEDS}->{$uri} = $feedname;
      $rssagg->add_feed( {
          name => $feedname, ## FIXME not guaranteed unique
          delay => 180,
          url => $uri,
        },
      );
      $core->log->debug("Added configured feed: $feedname ($uri)")
        if $core->debug > 1;
    }
  }
  
  my $sendto = $pcfg->{AnnounceTo};
  unless ($sendto && ref $sendto eq 'HASH') {
    $core->log->warn("Missing Channels: directive");
    $core->log->warn(
      "There are no contexts/channels configured.",
      "RSS output won't go anywhere...",
    );
    $self->{SendTo} = {};
  } else {
    ## Context (HASH) -> [ list of channels ]
    CONTEXT: for my $context (keys %$sendto) {
      next CONTEXT unless ref $context eq 'ARRAY'
                          and @$context;
      
      CHAN: for my $channel (@$context) {
        push( @{$self->{SendTo}->{$context}}, $channel );
        $core->log->debug("Added $channel to $context");
      }
    }
  }
    
  $core->log->info("Loaded - $VERSION");
  $core->plugin_register( $self, 'SERVER',
    [
      'public_cmd_rssaddfeed',
      'public_cmd_rssdelfeed',
    ],
  );
  return PLUGIN_EAT_NONE
}

sub Cobalt_unregister {
  my ($self, $core) = splice @_, 0, 2;
  ## shutdown component session  FIXME
  $core->log->info("Unloaded");
  return PLUGIN_EAT_NONE
}

sub Bot_public_cmd_rssaddfeed {
  my ($self, $core) = splice @_, 0, 2;
  my $context = ${ $_[0] };
  my $msg     = ${ $_[1] };
  
  my $nick = $msg->{src_nick};
  my $chan = $msg->{channel};
  
  my $auth_lev = $core->auth_level($context, $nick);

  my $pcfg = $core->get_plugin_cfg($self);
  my $minlev = $pcfg->{LevelRequired} // 3;

  return PLUGIN_EAT_NONE
    unless $core->auth_level($context, $nick) >= $minlev;
  
  my $auth_usr = $core->auth_username($context, $nick);
  
  my @args = @{ $msg->{message_array} };
  
  my ($feedname, $feedurl) = @args;
  unless ($feedname && $feedurl) {
    $core->send_event( 'send_message', $context, $chan,
      "A feed name and URL must be specified."
    );
    return PLUGIN_EAT_ALL
  }

  if ($self->{FEEDS}->{$feedurl}) {
    $core->send_event( 'send_message', $context, $chan,
      "Already tracking that feed."
    );
    return PLUGIN_EAT_ALL
  }

  my $rssagg = $self->{RSSAGG};
  $rssagg->add_feed( {
      name => $feedname, ## FIXME not guaranteed unique
      delay => 180,
      url => $feedurl,
    },
  );

  $self->{FEEDS}->{$feedurl} = $feedname;

  $core->send_event( 'send_message', $context, $chan,
    "Added new feed $feedname for $feedurl",
  );
  
  return PLUGIN_EAT_ALL 
}

sub Bot_public_cmd_rssdelfeed {

}


## POE

sub _start {
  my ($self, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];
  my $core = $self->core;
  my $poe_alias = 'rssagg'.$core->get_plugin_alias($self);

  $self->{RSSAGG} = POE::Component::RSSAggregator->new(
    alias => $poe_alias,
    callback => $session->postback("_feed"),
    tmpdir => File::Spec->tmpdir(),
  );
  
}

sub _feed {
  my ($self, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];
  my $core = $self->core;
  my $feed = $_[ARG1]->[0];
  my $title = $feed->title;
  HEAD: for my $headline ( $feed->late_breaking_news ) {
    my $this_line = $headline->headline;
    my $this_headline = "$this_line ($title)";
    
    CONTEXT: for my $context ( keys %{ $self->{SendTo} } ) {
      CHAN: for my $chan ( @$context ) {
        $core->log->debug("dispatching to $chan ($context)")
          if $core->debug > 1;
        $core->send_event( 'send_message', $context, $chan,
          color('bold', "RSS:")." $this_headline",
        );
      } ## CHAN
    } ## CONTEXT
  } ## HEAD
}

1;
__END__
