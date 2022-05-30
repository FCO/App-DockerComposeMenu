unit class App::DockerComposeMenu;
use Term::Choose;

class DockerComposeWrapper {

  method instance(|c) { $ //= self.WHAT.bless: |c }
  method new(|) {!!!}


  has IO  $.file     = "docker-compose.yml".IO;
  has Str @.cmd      = "docker", "compose", "-f", $!file.relative;
  has     @.services = self.outputs: "config", :services;

  method run(Str $cmd?, |c) {
    my @cmd = |@!cmd, |capture-to-args(|($_ with $cmd), |c);
    note @cmd if $*DEBUG;
    Proc::Async.new: @cmd
  }

  method outputs(Str $cmd?, |c) {
    my $proc = $.run(|($_ with $cmd), |c);
    my @output;
    $proc.stdout.lines.tap: { @output.push: $_ }
    await $proc.start;
    @output
  }

  sub capture-to-args(Str $cmd?, |c) {
    |($_ with $cmd), |c.hash.kv.map(-> $key, \value { pair-to-arg $key, value }), |c.list
  }

  multi pair-to-arg(Str $key, Bool $v where *.so)  { "-{"-" if $key.chars > 1}{ $key }" }
  multi pair-to-arg(Str $key, Bool $v where *.not) { "--no-{ $key }" }
  multi pair-to-arg(Str $key, @v)                  { |@v.map: { pair-to-arg $key, $_ } }
  multi pair-to-arg(Str $key, $v)                  { "-{"-" if $key.chars > 1}{ $key }=$v.Str()" }
}

class Page {
  has Str          $.prompt  is required;
  has              @.options;
  has Str          $.name    = $!prompt;
  has Str          $.info;
  has              %.conf    = :$!prompt, :2layout, :index, |(:!clear-screen if $*DEBUG);
  has Term::Choose $.choose .= new: |%!conf;
  has UInt         $.index   = 0;

  method all-options(Page $prev?) {
    |(
      |@.options,
      |($prev.defined
        ?? |("<< previous menu ({ $prev.name })" => "pop")
        !! |("!! quit !!"                        => "pop")
      ),
    )
  }

  method run(Page $prev?, UInt :default-index($default)) {
    my Pair @options = Array[Pair].new: |$.all-options: $prev;
    given $!choose.choose: :$default, |(:$!info with $!info), @options>>.key {
      when UInt:D {
        @options[$_].value
      }
      when !*.defined {
        "pop"
      }
    }
  }
}

class ServicesPage is Page {
  has                       @.cmd is required;
  has IO                    $.file      = "docker-compose.yml".IO;
  has DockerComposeWrapper  $.wrapper  .= instance: :$!file;
  has                       @.options   = self!options;

  method !get-flags(Str $desc) {
    shell "clear";
    my $flags = prompt("\o33[1mAny flag for '$desc'?\o33[m ");
    my @flags = $flags.words;
    @flags
  }

  method !options {
    "ALL SERVICES" => { "clear", "pop", $!wrapper.run: |(|@!cmd, |self!get-flags(@!cmd.head)) },
    |$!wrapper.services.sort.map: { $_ => { "clear", $!wrapper.run: |(|@!cmd, $_, |self!get-flags("$_ @!cmd.head()")) } };
  }
}

has IO                    $.file      = "docker-compose.yml".IO;
has DockerComposeWrapper  $.wrapper  .= instance: :$!file;
has Page                  @!pages handles <push pop>;

sub MAIN(
  IO(Str) :f(:$file) where { .f & .e & .r } = "docker-compose.yml", #= Docker compose file to be used
  Bool    :$debug,
) is export {
  my $*DEBUG = $_ with $debug;
  my $main = ::?CLASS.new(:$file).run
}

method TWEAK(|) {
  my @cmds = $!wrapper.outputs(:help).grep({ /^"Commands:"$/ ^ff^ /^\s*$/ })>>.trim;
  my @options = @cmds.kv.map: -> UInt $index, $_ {
    my ($cmd, $info) = .split: /\s+/, 2;
    $_ => ServicesPage.new: :$!file, :prompt($info ~ "\n"), :info($cmd.uc), :$cmd, :$index
  }
  $.push: Page.new:
    :prompt("What to do?"),
    :name("first menu"),
    :@options,
  ;
}

# method choose-service(:$prompt = "Choose a service:") {
#   $!choose.choose: @!services, :$prompt;
# }

multi method handle-response(@resp)   { $.handle-response: $_ for @resp }
multi method handle-response(Page $_) { $.push: .<>; Nil }
multi method handle-response("pop")   { $.pop }
multi method handle-response("clear") { shell "clear" unless $*DEBUG }
multi method handle-response(&resp)   { $.handle-response: resp }
multi method handle-response(Promise $prom) {
  await $prom;
  prompt "\nPress ENTER to continue."
}
multi method handle-response(Proc::Async $proc) {
  my $tap = signal(SIGINT).tap: -> $sig { note "killing..."; $proc.kill: $sig }
  $.handle-response: my $prom = $proc.start;
  $prom.then: { $tap.close }
}
multi method handle-response($_)      { Empty }

method run {
  my $default-index = 0;
  while @!pages {
    CATCH {
      default {
        .note if $*DEBUG;
      }
    }
    $default-index = do given $.handle-response: @!pages.tail.run: :$default-index, |(@!pages[*-2] if @!pages > 1) {
      when Page { .index }
      default   { 0 }
    }
  }
}
