class Subversion < Formula
  desc "Version control system designed to be a better CVS"
  homepage "https://subversion.apache.org/"
  url "https://www.apache.org/dyn/closer.cgi?path=subversion/subversion-1.13.0.tar.bz2"
  mirror "https://archive.apache.org/dist/subversion/subversion-1.13.0.tar.bz2"
  sha256 "bc50ce2c3faa7b1ae9103c432017df98dfd989c4239f9f8270bb3a314ed9e5bd"
  revision 1

  bottle do
    sha256 "138d0924e18d0994c2f50fefa8101e06573239a1937f972ee904bee0b84c79a3" => :catalina
    sha256 "6a92e47f2ccaaf22f7afce12df4196d6c3623caccdd2c322983b8b479474302f" => :mojave
    sha256 "eb8252001893f26f280241f9168a256c76999975c778a770922165587f7f1bac" => :high_sierra
  end

  head do
    url "https://github.com/apache/subversion.git", :branch => "trunk"

    depends_on "autoconf" => :build
    depends_on "automake" => :build
    depends_on "gettext" => :build
  end

  depends_on :java => ["1.8+", :build]
  depends_on "pkg-config" => :build
  depends_on "scons" => :build # For Serf
  depends_on "swig@3" => :build # https://issues.apache.org/jira/browse/SVN-4818
  depends_on "apr"
  depends_on "apr-util"

  # build against Homebrew versions of
  # gettext, lz4, perl, sqlite and utf8proc for consistency
  depends_on "gettext"
  depends_on "lz4"
  depends_on "openssl@1.1" # For Serf
  depends_on "perl"
  depends_on "sqlite"
  depends_on "utf8proc"

  resource "serf" do
    url "https://www.apache.org/dyn/closer.cgi?path=serf/serf-1.3.9.tar.bz2"
    mirror "https://archive.apache.org/dist/serf/serf-1.3.9.tar.bz2"
    sha256 "549c2d21c577a8a9c0450facb5cca809f26591f048e466552240947bdf7a87cc"
  end

  # Fix #23993 by stripping flags swig can't handle from SWIG_CPPFLAGS
  # Prevent "-arch ppc" from being pulled in from Perl's $Config{ccflags}
  # Prevent linking into a Python Framework
  patch :DATA

  def install
    ENV.prepend_path "PATH", "/System/Library/Frameworks/Python.framework/Versions/2.7/bin"

    serf_prefix = libexec/"serf"

    resource("serf").stage do
      # scons ignores our compiler and flags unless explicitly passed
      args = %W[
        PREFIX=#{serf_prefix} GSSAPI=/usr CC=#{ENV.cc}
        CFLAGS=#{ENV.cflags} LINKFLAGS=#{ENV.ldflags}
        OPENSSL=#{Formula["openssl@1.1"].opt_prefix}
        APR=#{Formula["apr"].opt_prefix}
        APU=#{Formula["apr-util"].opt_prefix}
      ]
      system "scons", *args
      system "scons", "install"
    end

    # Use existing system zlib
    # Use dep-provided other libraries
    # Don't mess with Apache modules (since we're not sudo)
    args = %W[
      --prefix=#{prefix}
      --disable-debug
      --enable-optimize
      --disable-mod-activation
      --disable-plaintext-password-storage
      --with-apr-util=#{Formula["apr-util"].opt_prefix}
      --with-apr=#{Formula["apr"].opt_prefix}
      --with-apxs=no
      --with-ruby-sitedir=#{lib}/ruby
      --with-serf=#{serf_prefix}
      --with-sqlite=#{Formula["sqlite"].opt_prefix}
      --with-zlib=#{MacOS.sdk_path_if_needed}/usr
      --without-apache-libexecdir
      --without-berkeley-db
      --without-gpg-agent
      --enable-javahl
      --without-jikes
      RUBY=/usr/bin/ruby
    ]

    # The system Python is built with llvm-gcc, so we override this
    # variable to prevent failures due to incompatible CFLAGS
    ENV["ac_cv_python_compile"] = ENV.cc

    inreplace "Makefile.in",
              "toolsdir = @bindir@/svn-tools",
              "toolsdir = @libexecdir@/svn-tools"

    system "./autogen.sh" if build.head?
    system "./configure", *args
    system "make"
    system "make", "install"
    bash_completion.install "tools/client-side/bash_completion" => "subversion"

    system "make", "tools"
    system "make", "install-tools"

    system "make", "swig-py"
    system "make", "install-swig-py"
    (lib/"python2.7/site-packages").install_symlink Dir["#{lib}/svn-python/*"]

    # Java and Perl support don't build correctly in parallel:
    # https://github.com/Homebrew/homebrew/issues/20415
    ENV.deparallelize
    system "make", "javahl"
    system "make", "install-javahl"

    archlib = Utils.popen_read("perl -MConfig -e 'print $Config{archlib}'")
    perl_core = Pathname.new(archlib)/"CORE"
    onoe "'#{perl_core}' does not exist" unless perl_core.exist?

    inreplace "Makefile" do |s|
      s.change_make_var! "SWIG_PL_INCLUDES",
        "$(SWIG_INCLUDES) -arch #{MacOS.preferred_arch} -g -pipe -fno-common -DPERL_DARWIN -fno-strict-aliasing -I#{HOMEBREW_PREFIX}/include -I#{perl_core}"
    end
    system "make", "swig-pl"
    system "make", "install-swig-pl"

    # This is only created when building against system Perl, but it isn't
    # purged by Homebrew's post-install cleaner because that doesn't check
    # "Library" directories. It is however pointless to keep around as it
    # only contains the perllocal.pod installation file.
    rm_rf prefix/"Library/Perl"
  end

  def caveats
    <<~EOS
      svntools have been installed to:
        #{opt_libexec}

      The perl bindings are located in various subdirectories of:
        #{opt_lib}/perl5

      You may need to link the Java bindings into the Java Extensions folder:
        sudo mkdir -p /Library/Java/Extensions
        sudo ln -s #{HOMEBREW_PREFIX}/lib/libsvnjavahl-1.dylib /Library/Java/Extensions/libsvnjavahl-1.dylib
    EOS
  end

  test do
    system "#{bin}/svnadmin", "create", "test"
    system "#{bin}/svnadmin", "verify", "test"
    system "perl", "-e", "use SVN::Client; new SVN::Client()"
  end
end

__END__
diff --git a/subversion/bindings/swig/perl/native/Makefile.PL.in b/subversion/bindings/swig/perl/native/Makefile.PL.in
index a60430b..bd9b017 100644
--- a/subversion/bindings/swig/perl/native/Makefile.PL.in
+++ b/subversion/bindings/swig/perl/native/Makefile.PL.in
@@ -76,10 +76,13 @@ my $apr_ldflags = '@SVN_APR_LIBS@'

 chomp $apr_shlib_path_var;

+my $config_ccflags = $Config{ccflags};
+$config_ccflags =~ s/-arch\s+\S+//g;
+
 my %config = (
     ABSTRACT => 'Perl bindings for Subversion',
     DEFINE => $cppflags,
-    CCFLAGS => join(' ', $cflags, $Config{ccflags}),
+    CCFLAGS => join(' ', $cflags, $config_ccflags),
     INC  => join(' ', $includes, $cppflags,
                  " -I$swig_srcdir/perl/libsvn_swig_perl",
                  " -I$svnlib_srcdir/include",

diff --git a/build/get-py-info.py b/build/get-py-info.py
index 29a6c0a..dd1a5a8 100644
--- a/build/get-py-info.py
+++ b/build/get-py-info.py
@@ -83,7 +83,7 @@ def link_options():
   options = sysconfig.get_config_var('LDSHARED').split()
   fwdir = sysconfig.get_config_var('PYTHONFRAMEWORKDIR')

-  if fwdir and fwdir != "no-framework":
+  if fwdir and fwdir != "no-framework" and sys.platform != 'darwin':

     # Setup the framework prefix
     fwprefix = sysconfig.get_config_var('PYTHONFRAMEWORKPREFIX')

diff --git a/subversion/libsvn_subr/io.c b/subversion/libsvn_subr/io.c
index 4bff69a..9d6db8f 100644
--- a/subversion/libsvn_subr/io.c
+++ b/subversion/libsvn_subr/io.c
@@ -216,7 +216,7 @@ cstring_to_utf8(const char **path_utf8,
                 const char *path_apr,
                 apr_pool_t *pool)
 {
-#if defined(WIN32)
+#if defined(WIN32) || defined(DARWIN)
   *path_utf8 = path_apr;
   return SVN_NO_ERROR;
 #else
@@ -299,7 +299,7 @@ entry_name_to_utf8(const char **name_p,
                    const char *parent,
                    apr_pool_t *pool)
 {
-#if defined(WIN32)
+#if defined(WIN32) || defined(DARWIN)
   *name_p = apr_pstrdup(pool, name);
   return SVN_NO_ERROR;
 #else
diff --git a/subversion/libsvn_subr/path.c b/subversion/libsvn_subr/path.c
index c286ecc..50a67de 100644
--- a/subversion/libsvn_subr/path.c
+++ b/subversion/libsvn_subr/path.c
@@ -40,9 +40,6 @@
 
 #include "dirent_uri.h"
 
-#if defined(DARWIN)
-#include <CoreFoundation/CoreFoundation.h>
-#endif /* DARWIN */
 
 /* The canonical empty path.  Can this be changed?  Well, change the empty
    test below and the path library will work, not so sure about the fs/wc
@@ -1114,7 +1111,7 @@ svn_path_get_absolute(const char **pabsolute,
 }
 
 
-#if !defined(WIN32)
+#if !defined(WIN32) && !defined(DARWIN)
 /** Get APR's internal path encoding. */
 static svn_error_t *
 get_path_encoding(svn_boolean_t *path_is_utf8, apr_pool_t *pool)
@@ -1141,7 +1138,7 @@ svn_path_cstring_from_utf8(const char **path_apr,
                            const char *path_utf8,
                            apr_pool_t *pool)
 {
-#if !defined(WIN32)
+#if !defined(WIN32) && !defined(DARWIN)
   svn_boolean_t path_is_utf8;
   SVN_ERR(get_path_encoding(&path_is_utf8, pool));
   if (path_is_utf8)
@@ -1150,7 +1147,7 @@ svn_path_cstring_from_utf8(const char **path_apr,
       *path_apr = apr_pstrdup(pool, path_utf8);
       return SVN_NO_ERROR;
     }
-#if !defined(WIN32)
+#if !defined(WIN32) && !defined(DARWIN)
   else
     return svn_utf_cstring_from_utf8(path_apr, path_utf8, pool);
 #endif
@@ -1162,38 +1159,18 @@ svn_path_cstring_to_utf8(const char **path_utf8,
                          const char *path_apr,
                          apr_pool_t *pool)
 {
-#if defined(DARWIN)
-  /*
-    Special treatment for Mac OS X to support UTF-8 MAC encodings.
-    Convert any decomposed unicode characters into precomposed ones.
-    This will solve the problem that the 'svn status' command sometimes
-    cannot recognize the same file if it contains composed characters,
-    like Umlaut in some European languages.
-  */
-  CFMutableStringRef cfmsr = CFStringCreateMutable(NULL, 0);
-  CFStringAppendCString(cfmsr, path_apr, kCFStringEncodingUTF8);
-  CFStringNormalize(cfmsr, kCFStringNormalizationFormC);
-  CFIndex path_buff_size = 1 + CFStringGetMaximumSizeForEncoding(CFStringGetLength(cfmsr), kCFStringEncodingUTF8);
-  path_apr = apr_palloc(pool, path_buff_size);
-  CFStringGetCString(cfmsr, path_apr, path_buff_size, kCFStringEncodingUTF8);
-  CFRelease(cfmsr);
-  *path_utf8 = path_apr;
-  return SVN_NO_ERROR;
-#else
-  /* Use the default method on any other OS */
- #if !defined(WIN32)
+#if !defined(WIN32) && !defined(DARWIN)
   svn_boolean_t path_is_utf8;
   SVN_ERR(get_path_encoding(&path_is_utf8, pool));
   if (path_is_utf8)
- #endif
+#endif
     {
       *path_utf8 = apr_pstrdup(pool, path_apr);
       return SVN_NO_ERROR;
     }
-  #if !defined(WIN32)
+#if !defined(WIN32) && !defined(DARWIN)
   else
     return svn_utf_cstring_to_utf8(path_utf8, path_apr, pool);
-  #endif
 #endif
 }
 
diff --git a/subversion/svn/proplist-cmd.c b/subversion/svn/proplist-cmd.c
index f498365..80e0364 100644
--- a/subversion/svn/proplist-cmd.c
+++ b/subversion/svn/proplist-cmd.c
@@ -98,11 +98,6 @@ proplist_receiver_xml(void *baton,
   else
     name_local = path;
 
-#if defined(DARWIN)
-  if (! is_url)
-    SVN_ERR(svn_path_cstring_to_utf8(&name_local, name_local, pool));
-#endif
-
   sb = NULL;
 
 
@@ -142,11 +137,6 @@ proplist_receiver(void *baton,
   else
     name_local = path;
 
-#if defined(DARWIN)
-  if (! is_url)
-    SVN_ERR(svn_path_cstring_to_utf8(&name_local, name_local, pool));
-#endif
-
   if (inherited_props)
     {
       int i;
diff --git a/subversion/svn/status-cmd.c b/subversion/svn/status-cmd.c
index 5abb4e7..7692eb3 100644
--- a/subversion/svn/status-cmd.c
+++ b/subversion/svn/status-cmd.c
@@ -114,10 +114,6 @@ print_start_target_xml(const char *target, apr_pool_t *pool)
 {
   svn_stringbuf_t *sb = svn_stringbuf_create_empty(pool);
 
-#if defined(DARWIN)
-  SVN_ERR(svn_path_cstring_to_utf8(&target, target, pool));
-#endif
-
   svn_xml_make_open_tag(&sb, pool, svn_xml_normal, "target",
                         "path", target, SVN_VA_NULL);
 
