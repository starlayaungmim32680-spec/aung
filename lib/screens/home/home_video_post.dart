// Part of home_screen.dart - split out 14 Oct 2026 (step 6 of breaking up
// the big file, a piece at a time). The one video post the whole app is
// built around: _VideoPostItem and its State (player + preload cache,
// tap / double-tap / long-press, like & reaction picker, comments /
// share / save / repost / download buttons, owner info + caption
// overlay, follow, report / block, live text overlays and filters).
// Every feed (Home, Shorts, profile, saved, single, notification) shows
// these. Moved unchanged - later steps can split its State further.
part of '../home_screen.dart';

class _VideoPostItem extends StatefulWidget {
  final String postId;
  final String userId;
  final String videoUrl;
  final String caption;
  final String userEmail;
  final Map<String, dynamic> reactions;
  final String videoType;
  final VoidCallback onVideoEnd;
  // When this video is being shown as a repost, these carry the sharer's
  // own note and name so it can be displayed on top of the video.
  final String? repostNote;
  final String? repostByName;
  final String? repostByUserId;
  final String? repostByPhoto;
  // Playback effects chosen at upload time (see video_effects_screen.dart).
  final double videoSpeed;
  final String filterType;
  final bool blurBackground;
  final List<TextOverlayData> textOverlays;
  // True once speed/filter/text/sticker effects are baked directly into
  // videoUrl itself (Cloudinary transformations applied at upload time) -
  // when true, videoSpeed/filterType/textOverlays above are only kept as
  // editable metadata and must NOT be re-applied during playback, or the
  // effects would show twice. False for older posts uploaded before this
  // existed, which still need the client-side overlay/color-filter below.
  final bool effectsBaked;
  // When set, a single tap on the video calls this instead of the normal
  // play/pause toggle - used on the compact Home feed to open the video
  // in FullScreenVideoScreen (see below), where the header/stories bar no
  // longer eats into the video's height. Left null inside that fullscreen
  // screen itself, so tapping there behaves normally (play/pause).
  final Future<dynamic> Function()? onTapToExpand;
  // Opened from a notification (PostFromNotificationScreen, 1 Oct 2026):
  // open the comments right away (spotlighting [highlightCommentFrom]'s
  // comment), and/or burst [burstEmojiOnStart] over the video.
  final bool openCommentsOnStart;
  final String? highlightCommentFrom;
  final String? highlightCommentText;
  // Reply notification (10 Oct 2026): spotlight this comment by id and
  // open its replies.
  final String? highlightCommentId;
  final String? burstEmojiOnStart;

  const _VideoPostItem({
    super.key,
    required this.postId,
    required this.userId,
    required this.videoUrl,
    required this.caption,
    required this.userEmail,
    required this.reactions,
    required this.videoType,
    required this.onVideoEnd,
    this.repostNote,
    this.repostByName,
    this.repostByUserId,
    this.repostByPhoto,
    this.videoSpeed = 1.0,
    this.filterType = 'none',
    this.blurBackground = true,
    this.textOverlays = const [],
    this.effectsBaked = false,
    this.onTapToExpand,
    this.openCommentsOnStart = false,
    this.highlightCommentFrom,
    this.highlightCommentText,
    this.highlightCommentId,
    this.burstEmojiOnStart,
  });

  @override
  State<_VideoPostItem> createState() => _VideoPostItemState();
}

class _VideoPostItemState extends State<_VideoPostItem>
    with RouteAware, WidgetsBindingObserver {
  // How many times a video replays on its own before we auto-advance to
  // the next one. The user can still swipe away manually at any time.
  static const int _maxLoopsBeforeAutoSkip = 3;
  // Height of the solid black caption/username/sound panel below the
  // video (see build()) - the video is sized to leave exactly this much
  // room, rather than the panel floating on top of it.
  static const double _kCaptionPanelHeight = 128;

  // Wraps [child] in a ColorFiltered matrix ONLY when the uploader actually
  // picked a filter at post time. Most videos have none, so this skips the
  // ColorFiltered layer entirely rather than applying a technically-identity
  // matrix - some devices render even an identity ColorFilter with a very
  // slight colour/gamma shift, and the goal is the video looking exactly
  // like what was uploaded, with nothing added.
  Widget _withOptionalFilter(Widget child) {
    final String effectiveFilter =
        widget.effectsBaked ? 'none' : widget.filterType;
    if (effectiveFilter == 'none') return child;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(kVideoFilterMatrices[effectiveFilter] ??
          kVideoFilterMatrices['none']!),
      child: child,
    );
  }

  VideoPlayerController? _controller;
  bool _isInitialized = false;
  // True when the video failed to load (network error/timeout) - shows a
  // friendly error + retry button instead of a spinner that never resolves.
  bool _hasError = false;
  // True while a freshly uploaded Bunny video is still being encoded -
  // its playlist.m3u8 doesn't exist yet for the first moments/minutes
  // after upload. Shows "Processing video..." and retries on its own
  // instead of the "Couldn't load" error.
  bool _isProcessing = false;
  Timer? _processingRetryTimer;
  // Early-Play (16 Oct 2026): while Bunny is still encoding a fresh upload
  // its playlist.m3u8 doesn't exist yet, but the ORIGINAL file is already
  // on the CDN (library setting "Early-Play" + "Keep original files").
  // [_useOriginal] makes the next load play that file; [_triedOriginal]
  // makes sure we only try it once per round before showing "Processing".
  bool _useOriginal = false;
  bool _triedOriginal = false;
  // Stall watchdog: sometimes (mostly the very first video after opening
  // the app, on a slow start) initialize() finished but the stream never
  // actually started - a black screen with no spinner. If playback was
  // asked for but hasn't moved after _stallTimeout, the controller is
  // rebuilt once automatically.
  Timer? _stallTimer;
  int _stallRetries = 0;
  static const Duration _stallTimeout = Duration(seconds: 8);
  static const int _maxStallRetries = 2;
  // Last video size the layout was built with. HLS (Bunny) streams can
  // report a size of 0x0 at initialize() and the real size a moment later;
  // the layout is rebuilt when it changes (see _onVideoProgress).
  Size _lastVideoSize = Size.zero;
  // Cached post upload time (read once, only after a failed load).
  DateTime? _postCreatedAt;
  bool _postCreatedAtLoaded = false;
  bool _endTriggered = false;
  int _loopCount = 0;
  bool _showReactionPicker = false;

  // Controls visibility is a notifier so toggling it rebuilds ONLY the overlay,
  // not the whole video item (avoids flicker on every tap).
  final ValueNotifier<bool> _controlsVisible = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _muted = ValueNotifier<bool>(false);

  final List<_FlyingEmoji> _flyingEmojis = [];

  // Double-tap like (15 Oct 2026, TikTok style): where the finger landed,
  // and the big hearts currently popping there.
  Offset? _doubleTapPos;
  final List<({int id, Offset pos})> _tapHearts = [];

  // Built once, for the same reason as the feed streams: creating it
  // inside build() would resubscribe on every rebuild.
  Stream<DocumentSnapshot>? _postDocStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.postId.isNotEmpty) {
      _postDocStream = FirebaseFirestore.instance
          .collection('posts')
          .doc(widget.postId)
          .snapshots();
    }
    _initializeVideo();
    _recordView();
    if (widget.openCommentsOnStart || widget.burstEmojiOnStart != null) {
      // A beat after the screen slides in, so it reads as a reveal.
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        final String? emoji = widget.burstEmojiOnStart;
        if (emoji != null && emoji.isNotEmpty) _spawnReactionBurst(emoji);
        if (widget.openCommentsOnStart) _openComments();
      });
    }
  }

  // A fountain of the same reaction (opening a "reacted to your video"
  // notification) - several emojis at different sizes, drifts and delays.
  void _spawnReactionBurst(String emoji) {
    final Random rnd = Random();
    final int base = DateTime.now().microsecondsSinceEpoch;
    for (int i = 0; i < 9; i++) {
      _flyingEmojis.add(_FlyingEmoji(
        id: base + i,
        emoji: emoji,
        startX: -rnd.nextDouble() * 70,
        horizontalDrift: (rnd.nextDouble() * 60) - 30,
        size: 26 + rnd.nextDouble() * 24,
        delayMs: i * 110,
      ));
    }
    setState(() {});
    HapticFeedback.lightImpact();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      flyRouteObserver.subscribe(this, route);
    }
  }

  // Remembers whether playback was running, so returning resumes only
  // videos that were actually playing.
  //
  // Two separate "away" reasons are tracked, because they overlap:
  //   _routeCovered     - another screen was pushed on top (didPushNext)
  //   _appBackgrounded  - Fly left the foreground (Home button, recents,
  //                       a call...)
  // Bug this fixes (28-29 Sep 2026): leaving with the phone's Home button
  // fires several lifecycle events in a row (inactive -> hidden ->
  // paused). The first one paused the video; the next ones then saw it
  // "not playing" and overwrote the flag with false - so coming back via
  // recents never resumed it, and the video sat there black and silent.
  // Now only the FIRST away-reason records the state; later ones are
  // ignored until everything is clear again.
  bool _wasPlayingBeforeLeaving = false;
  bool _routeCovered = false;
  bool _appBackgrounded = false;

  bool get _isAway => _routeCovered || _appBackgrounded;

  void _pauseForNavigation() {
    if (_isAway) return; // already paused for an earlier reason
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      _wasPlayingBeforeLeaving = false;
      return;
    }
    _wasPlayingBeforeLeaving = c.value.isPlaying;
    if (c.value.isPlaying) c.pause();
  }

  void _resumeAfterNavigation() {
    if (_isAway) return; // still covered / still in the background
    final c = _controller;
    if (c == null) return;
    // The phone may have torn the player down while Fly was in the
    // background (some OEM skins do this to save memory) - rebuild it at
    // the same spot instead of calling play() on a dead player.
    if (!c.value.isInitialized || c.value.hasError) {
      _reloadAt(c.value.position, autoPlay: _wasPlayingBeforeLeaving);
      _wasPlayingBeforeLeaving = false;
      return;
    }
    if (_wasPlayingBeforeLeaving) {
      c.play();
      // If it still doesn't move (surface lost in the background), the
      // watchdog rebuilds it - see _startStallWatchdog.
      _startStallWatchdog(c, from: c.value.position);
    } else {
      // Paused on purpose before leaving (bug seen 29 Sep 2026): Android
      // throws away the video's drawing surface while Fly is in the
      // background, and a paused player never draws a new frame on its
      // own - so it came back black. Seeking to the same spot makes the
      // player draw that frame again, and it stays paused.
      c.seekTo(c.value.position);
    }
    _wasPlayingBeforeLeaving = false;
  }

  // Another full screen was pushed on top of this one - stop the sound.
  @override
  void didPushNext() {
    _pauseForNavigation();
    _routeCovered = true;
  }

  // That screen was closed and this one is visible again.
  @override
  void didPopNext() {
    _routeCovered = false;
    _resumeAfterNavigation();
  }

  // App sent to the background / a call came in, etc.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appBackgrounded = false;
      _resumeAfterNavigation();
    } else {
      _pauseForNavigation();
      _appBackgrounded = true;
    }
  }

  // Records that the current user viewed this post (counted once per user).
  Future<void> _recordView() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || widget.postId.isEmpty) return;

    final postRef =
        FirebaseFirestore.instance.collection('posts').doc(widget.postId);
    final viewRef = postRef.collection('views').doc(user.uid);
    try {
      final snap = await viewRef.get();
      if (!snap.exists) {
        await viewRef.set({'createdAt': FieldValue.serverTimestamp()});
      }
    } catch (_) {
      // Ignore view-tracking errors so playback is never affected.
    }
  }

  Widget _positionedOverlayText(TextOverlayData overlay) {
    final double fontSize = (overlay.isSticker ? 56 : 20) * overlay.scale;
    return IgnorePointer(
      child: Align(
        alignment: Alignment(overlay.dx * 2 - 1, overlay.dy * 2 - 1),
        child: overlay.imageUrl != null
            ? Image.network(overlay.imageUrl!,
                width: 80 * overlay.scale, height: 80 * overlay.scale)
            : overlay.isSticker
                ? Text(overlay.text, style: TextStyle(fontSize: fontSize))
                : AnimatedOverlayText(
                    text: overlay.text,
                    fontSize: fontSize,
                    color: overlay.color,
                    styleId: overlay.styleId,
                    animationId: overlay.animationId,
                  ),
      ),
    );
  }

  // How long to wait for a fresh video fetch to finish initializing before
  // giving up and showing a retry button instead of spinning forever. Only
  // applies to a genuinely fresh network fetch - an already-preloaded
  // (claimed) controller is initialized instantly, no network wait needed.
  static const Duration _initTimeout = Duration(seconds: 12);

  // How long after upload a failed load is treated as "still encoding"
  // rather than a real error, and how often to retry meanwhile.
  static const Duration _processingWindow = Duration(minutes: 30);
  static const Duration _processingRetryEvery = Duration(seconds: 5);

  // A load failure right after upload is almost always Bunny still
  // encoding, not a real error. Only HLS (Bunny) videos qualify - old
  // Cloudinary mp4s were ready the moment they were uploaded.
  Future<bool> _looksFreshlyUploaded() async {
    if (!widget.videoUrl.contains('.m3u8')) return false;
    if (!_postCreatedAtLoaded) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('posts')
            .doc(widget.postId)
            .get();
        // No such post (e.g. a repost id) - can't be a fresh upload.
        if (!snap.exists) return false;
        final Timestamp? ts = snap.data()?['createdAt'] as Timestamp?;
        _postCreatedAt = ts?.toDate();
        _postCreatedAtLoaded = true;
      } catch (_) {
        // Can't tell (e.g. offline) - fall back to the normal error.
        return false;
      }
    }
    // No timestamp yet = the server hasn't even confirmed the write, so
    // it's certainly brand new.
    if (_postCreatedAt == null) return true;
    return DateTime.now().difference(_postCreatedAt!) < _processingWindow;
  }

  void _scheduleProcessingRetry() {
    _processingRetryTimer?.cancel();
    _processingRetryTimer = Timer(_processingRetryEvery, () {
      if (!mounted) return;
      // New round: try the encoded stream first, then the original again.
      _useOriginal = false;
      _triedOriginal = false;
      _initializeVideo();
    });
  }

  // https://host/<id>/playlist.m3u8  ->  https://host/<id>/original
  // Only for Bunny Stream HLS urls; anything else returns null.
  String? _originalFileUrl() {
    final String url = widget.videoUrl;
    if (!url.contains('b-cdn.net') || !url.endsWith('/playlist.m3u8')) {
      return null;
    }
    return '${url.substring(0, url.length - 'playlist.m3u8'.length)}original';
  }

  // [startAt]: resume from this position (used when a stuck or torn-down
  // player is rebuilt mid-video) instead of from the beginning.
  // [autoPlay]: false rebuilds a video the person had paused - it comes
  // back showing its frame, still paused.
  Future<void> _initializeVideo(
      {Duration? startAt, bool autoPlay = true}) async {
    if (widget.videoUrl.isEmpty) return;

    _processingRetryTimer?.cancel();
    if (mounted && _hasError) {
      setState(() => _hasError = false);
    }

    // Early-Play: after the encoded stream failed on a fresh upload, play
    // the original file instead of waiting for Bunny (see _useOriginal).
    final String? originalUrl = _useOriginal ? _originalFileUrl() : null;
    final String playUrl = originalUrl ?? playableVideoUrl(widget.videoUrl);

    // If this video was already preloaded while the previous one was
    // playing, reuse that controller instead of starting a fresh network
    // fetch — this is what makes swiping to the next video feel instant.
    VideoPlayerController? controller =
        VideoPreloadCache.claim(widget.videoUrl);

    try {
      // True once playback is actually coming off a local file already on
      // disk from a previous watch - if so, there's no need to re-save it
      // (it's already there) and this view worked with zero network use.
      bool playingFromDisk = false;

      // An HLS video (Bunny Stream's playlist.m3u8 - see media_utils.dart)
      // is a small text manifest that references separate segment files
      // by URL, not a single self-contained video file the way a plain
      // Cloudinary mp4 was. Caching just that manifest as a local file
      // doesn't provide real offline playback (the segments still live
      // on the CDN) and actively breaks playback when reloaded from
      // disk, since the manifest's relative segment references can't
      // resolve against a local file:// path the way they resolve
      // against the real CDN URL. So HLS videos always stream directly
      // and skip VideoDiskCache entirely - true offline HLS caching
      // would need downloading every segment and rewriting the manifest
      // to point at them locally, which is a separate, bigger feature.
      final bool isHlsVideo = widget.videoUrl.contains('.m3u8');

      // The uploader's own just-posted video: play the file that's still
      // on this phone - instant, and works before Bunny finishes encoding.
      if (controller == null) {
        final File? localUpload = LocalVideoCache.fileFor(widget.videoUrl);
        if (localUpload != null) {
          controller = VideoPlayerController.file(localUpload);
          playingFromDisk = true;
          await controller.initialize().timeout(_initTimeout);
        }
      }

      if (controller == null) {
        File? cachedFile;
        if (!isHlsVideo) {
          // A video watched before may already be sitting on disk (see
          // VideoDiskCache) - check that first so a re-watch, including
          // with no connection at all, plays instantly instead of
          // re-streaming.
          try {
            final FileInfo? info =
                await VideoDiskCache.instance.getFileFromCache(widget.videoUrl);
            cachedFile = info?.file;
          } catch (_) {
            // Cache lookup itself failing just means falling through to a
            // normal network fetch below - never worth surfacing as an
            // error.
          }
        }

        if (cachedFile != null && await cachedFile.exists()) {
          controller = VideoPlayerController.file(cachedFile);
          playingFromDisk = true;
        } else {
          controller = VideoPlayerController.networkUrl(Uri.parse(playUrl));
        }
        await controller.initialize().timeout(_initTimeout);
      }

      // This video is now actually being watched - save a copy to disk in
      // the background (unless it's already there, or it's HLS - see
      // above) so next time it can replay fully offline.
      if (!playingFromDisk && !isHlsVideo) {
        _cacheVideoInBackground(playUrl, cacheKey: widget.videoUrl);
      }

      await controller.setVolume(1);
      // Baked posts already play at the chosen speed inside the file itself
      // (see video_effects_baker.dart) - applying videoSpeed again on top
      // would speed it up/slow it down a second time.
      if (!widget.effectsBaked) {
        await controller.setPlaybackSpeed(widget.videoSpeed);
      }
      if (startAt != null && startAt > Duration.zero) {
        await controller.seekTo(startAt);
      }
      // Don't start playing if the screen was covered / Fly went to the
      // background while this was loading - remember to play on return.
      if (!autoPlay) {
        // Stay paused (the seek above already drew the frame).
      } else if (_isAway) {
        _wasPlayingBeforeLeaving = true;
      } else {
        controller.play();
      }
      controller.addListener(_onVideoProgress);

      if (mounted) {
        _lastVideoSize = controller.value.size;
        setState(() {
          _controller = controller;
          _isInitialized = true;
          _isProcessing = false;
        });
        _startStallWatchdog(controller);
      } else {
        // Scrolled away / disposed while this load was in flight.
        controller.removeListener(_onVideoProgress);
        controller.dispose();
      }
    } catch (_) {
      controller?.dispose();
      if (!mounted) return;

      // Freshly uploaded and Bunny is still encoding it. First try the
      // original file right away (Early-Play) so nobody has to wait.
      if (await _looksFreshlyUploaded()) {
        if (!mounted) return;
        if (!_triedOriginal && _originalFileUrl() != null) {
          _triedOriginal = true;
          _useOriginal = true;
          _initializeVideo(startAt: startAt, autoPlay: autoPlay);
          return;
        }
        // The original didn't work either - keep a calm "Processing"
        // state and quietly retry until it's ready.
        setState(() {
          _isInitialized = false;
          _hasError = false;
          _isProcessing = true;
        });
        _scheduleProcessingRetry();
        return;
      }

      // Network failure, timeout, or an unreachable/corrupt stream - show
      // a friendly error + retry button instead of the spinner staying up
      // forever, which was the previous behavior on a lost connection.
      if (!mounted) return;
      setState(() {
        _isInitialized = false;
        _hasError = true;
        _isProcessing = false;
      });
    }
  }

  // See _stallTimer. Only acts when playback was actually requested
  // (isPlaying) - a video paused on purpose, or by leaving the screen,
  // naturally doesn't move and must not be reloaded. [from] is where
  // playback started (0:00 for a fresh load, the resume point after
  // coming back to the app); "stuck" means it never got past it.
  void _startStallWatchdog(VideoPlayerController controller,
      {Duration from = Duration.zero}) {
    _stallTimer?.cancel();
    _stallTimer = Timer(_stallTimeout, () {
      if (!mounted || !identical(controller, _controller) || _isAway) return;
      final VideoPlayerValue v = controller.value;
      final bool stuck = v.isPlaying && v.position <= from;
      if (!stuck) {
        _stallRetries = 0; // healthy again - allow retries next time
        return;
      }
      _reloadAt(from);
    });
  }

  // Throws away the current (stuck / dead) player and builds a fresh one
  // at [at]. After _maxStallRetries attempts, shows the normal
  // "Couldn't load - tap to retry" instead of a silent black screen.
  void _reloadAt(Duration at, {bool autoPlay = true}) {
    final VideoPlayerController? old = _controller;
    final bool giveUp = _stallRetries >= _maxStallRetries;
    if (!giveUp) _stallRetries++;

    // Take the old controller off screen first, and only dispose it after
    // that frame - disposing it while VideoPlayer/_FirstFrameCover are
    // still listening to it would throw.
    old?.removeListener(_onVideoProgress);
    setState(() {
      _controller = null;
      _isInitialized = false;
      _hasError = giveUp;
    });
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }

    if (!giveUp) _initializeVideo(startAt: at, autoPlay: autoPlay);
  }

  // Fire-and-forget: downloads this video to disk for offline replay next
  // time. Stored under [cacheKey] - the original, unmodified video URL -
  // rather than [url] itself, since [url] can be either the normal or the
  // network-adaptive low-quality Cloudinary transform (see
  // playableVideoUrl in media_utils.dart) depending on the connection at
  // the moment this is called. Without a stable key, a video cached while
  // online (normal-quality URL) would silently miss the cache when looked
  // up again later while offline (low-quality URL) - looking like caching
  // never worked at all.
  //
  // Never awaited by the caller and always swallows its own errors, so a
  // slow connection or a caching failure can never delay or disrupt the
  // playback that's already happening.
  void _cacheVideoInBackground(String url, {required String cacheKey}) {
    () async {
      try {
        await VideoDiskCache.instance.downloadFile(url, key: cacheKey);
      } catch (_) {
        // Not being able to cache a video isn't worth surfacing - it just
        // streams again next time instead of playing from disk.
      }
    }();
  }

  // Called when the person taps the retry button in the error state.
  void _retryVideoLoad() {
    _stallRetries = 0;
    _initializeVideo();
  }

  void _onVideoProgress() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    // The real video size arrived after initialize() (common with HLS):
    // rebuild once so Smart Fit uses the right shape. Only on a size
    // change - not on every position tick.
    final Size size = controller.value.size;
    if (size != _lastVideoSize) {
      _lastVideoSize = size;
      if (mounted) setState(() {});
    }

    final position = controller.value.position;
    final duration = controller.value.duration;

    if (!_endTriggered &&
        duration.inMilliseconds > 0 &&
        position.inMilliseconds >= duration.inMilliseconds - 200) {
      _endTriggered = true;
      _loopCount++;
      CoinService.instance.awardWatchComplete();

      if (_loopCount >= _maxLoopsBeforeAutoSkip) {
        // Watched the same video 3 times in a row without the user
        // swiping away themselves — move on to the next one.
        widget.onVideoEnd();
      } else {
        // Replay it for another loop.
        controller.seekTo(Duration.zero);
        controller.play();
        // Give the seek a moment to land before watching for the end
        // again, so the same loop isn't counted twice.
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _endTriggered = false;
        });
      }
    }
  }

  void _handleScreenTap() {
    if (_showReactionPicker) {
      setState(() => _showReactionPicker = false);
      return;
    }
    if (widget.onTapToExpand != null) {
      _expandToFullScreen();
      return;
    }
    _togglePlayPause();
  }

  // 18 Oct 2026: tapping a Home video opens the same video full-screen.
  // The full-screen copy used to open a brand-new player (a network
  // start = spinner) while this one was already playing. Now this
  // already-playing player is HANDED OVER (VideoPreloadCache.adopt ->
  // the full-screen item claims it), so it carries on from the same
  // second with no spinner. This item then starts a fresh player for
  // itself in the background so it is ready when the person comes back.
  bool _expanding = false;
  Future<void> _expandToFullScreen() async {
    if (_expanding) return;
    _expanding = true;
    try {
      final c = _controller;
      if (c != null && c.value.isInitialized && !c.value.hasError) {
        _stallTimer?.cancel();
        c.removeListener(_onVideoProgress);
        VideoPreloadCache.adopt(widget.videoUrl, c);
        setState(() {
          _controller = null;
          _isInitialized = false;
        });
        // After the full-screen item has claimed it, prepare a new player
        // for the way back (a no-op if the hand-over has not happened).
        Future.delayed(const Duration(milliseconds: 800), () {
          VideoPreloadCache.preload(widget.videoUrl);
        });
      }
      await widget.onTapToExpand!();
      if (!mounted) return;
      if (_controller == null) _initializeVideo();
    } finally {
      _expanding = false;
    }
  }

  // Skips forward/backward by [seconds]; keeps the controls visible
  void _seekBy(int seconds) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    Duration target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > c.value.duration) target = c.value.duration;
    c.seekTo(target);
    _controlsVisible.value = true;
  }

  // Playing -> pause and show the 3 controls; Paused -> play and hide them
  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      _controlsVisible.value = true;
    } else {
      c.play();
      _controlsVisible.value = false;
    }
  }

  void _toggleMute() {
    _muted.value = !_muted.value;
    _controller?.setVolume(_muted.value ? 0.0 : 1.0);
  }

  // Formats a duration as m:ss (e.g. 0:08, 1:23)
  String _fmtDuration(Duration d) {
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // A single circular media-control button
  Widget _circleControl({
    required IconData icon,
    required double diameter,
    required double iconSize,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.45),
        ),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }

  void _spawnFlyingEmojis(String emoji) {
    final flyingEmoji = _FlyingEmoji(
      id: DateTime.now().microsecondsSinceEpoch,
      emoji: emoji,
      startX: 0,
      horizontalDrift: 20,
      size: 40,
      delayMs: 0,
    );
    _flyingEmojis.add(flyingEmoji);
    setState(() {});
  }

  void _removeFlyingEmoji(int id) {
    _flyingEmojis.removeWhere((e) => e.id == id);
    if (mounted) setState(() {});
  }

  Future<void> _createNotification({
    required String type,
    required String text,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (widget.userId.isEmpty || widget.userId == user.uid) return;

    final myProfile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = myProfile.data();
    final String myName =
        (data?['displayName'] as String?)?.trim().isNotEmpty == true
            ? data!['displayName']
            : (user.email?.split('@').first ?? 'Someone');
    final String myPhoto = (data?['photoUrl'] as String?) ?? '';

    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.userId)
        .collection('notifications')
        .add({
      'type': type,
      'text': text,
      'fromId': user.uid,
      'fromName': myName,
      'fromPhoto': myPhoto,
      'postId': widget.postId,
      'seen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Toggles a reaction. [currentReactions] must be the FRESHEST reactions map
  // available (from the live post-document stream, not a value cached from
  // when this widget was first built) so the like/unlike decision below is
  // always correct, even if several taps happen quickly.
  Future<void> _setReaction(
      String type, Map<String, dynamic> currentReactions) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final postRef =
        FirebaseFirestore.instance.collection('posts').doc(widget.postId);
    final String? currentReaction = currentReactions[user.uid] as String?;

    setState(() => _showReactionPicker = false);

    if (currentReaction == type) {
      await postRef.update({'reactions.${user.uid}': FieldValue.delete()});
    } else {
      await postRef.update({'reactions.${user.uid}': type});
      _spawnFlyingEmojis(kReactions[type]!);
      _createNotification(type: 'reaction', text: kReactions[type]!);
    }
  }

  void _quickToggleLike(Map<String, dynamic> currentReactions) {
    _setReaction('like', currentReactions);
  }

  // Double-tap anywhere on the video (15 Oct 2026, TikTok style): a big
  // heart pops where the finger landed, and the video gets my like if I
  // haven't reacted yet. Like TikTok it NEVER takes a like back - tapping
  // twice again just shows another heart.
  void _onDoubleTapLike(Map<String, dynamic> currentReactions) {
    HapticFeedback.lightImpact();
    final Offset? pos = _doubleTapPos;
    if (pos != null) {
      setState(() => _tapHearts
          .add((id: DateTime.now().microsecondsSinceEpoch, pos: pos)));
    }
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (currentReactions[uid] == null) {
      _setReaction('like', currentReactions);
    }
  }

  // Shows a small dialog so the sharer can add their own words on top of
  // the video before sharing. Returns null if they cancelled, or the note
  // text (possibly empty) if they tapped Share.
  Future<String?> _showShareNoteDialog() async {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Share video', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          maxLines: 3,
          maxLength: 150,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Add your own words... (optional)',
            hintStyle: TextStyle(color: Colors.grey),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.redAccent),
            ),
            counterStyle: TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child:
                const Text('Share', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _shareVideo() async {
    final String? note = await _showShareNoteDialog();
    if (note == null) return; // User cancelled the dialog

    // Record the share so it can be counted (one per user, idempotent)
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && widget.postId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('posts')
            .doc(widget.postId)
            .collection('shares')
            .doc(user.uid)
            .set({'createdAt': FieldValue.serverTimestamp()});
        CoinService.instance.awardShare();
      } catch (_) {
        // Ignore share-tracking errors
      }

      // Look up the sharer's own display name + photo so their account is
      // clearly visible ("<name> shared this") wherever the repost appears.
      String sharedByName = widget.userEmail;
      String sharedByPhoto = '';
      try {
        final myProfile = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final data = myProfile.data();
        sharedByName =
            (data?['displayName'] as String?)?.trim().isNotEmpty == true
                ? data!['displayName']
                : (user.email?.split('@').first ?? 'Someone');
        sharedByPhoto = (data?['photoUrl'] as String?) ?? '';
      } catch (_) {
        // Keep the fallback name above
      }

      // Also save this as a "repost" on the sharer's own profile, so
      // anyone visiting their profile can see the video they shared -
      // along with the note they wrote on top of it.
      // Doc id is uid_postId so re-sharing the same video is idempotent
      // (just refreshes the timestamp) instead of creating duplicates.
      try {
        await FirebaseFirestore.instance
            .collection('reposts')
            .doc('${user.uid}_${widget.postId}')
            .set({
          'sharedBy': user.uid,
          'sharedByName': sharedByName,
          'sharedByPhoto': sharedByPhoto,
          'originalPostId': widget.postId,
          'originalUserId': widget.userId,
          'videoUrl': widget.videoUrl,
          'caption': widget.caption,
          'videoType': widget.videoType,
          'videoSpeed': widget.videoSpeed,
          'filterType': widget.filterType,
          'textOverlays': widget.textOverlays.map((o) => o.toMap()).toList(),
          'effectsBaked': widget.effectsBaked,
          'userEmail': widget.userEmail,
          'note': note,
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {
        // Ignore repost-tracking errors
      }
    }

    final String shareText = note.isNotEmpty
        ? '$note\n\nWatch on Fly: ${widget.videoUrl}'
        : widget.caption.isNotEmpty
            ? '${widget.caption}\n\nWatch on Fly: ${widget.videoUrl}'
            : 'Watch this video on Fly: ${widget.videoUrl}';
    await Share.share(shareText);
  }

  // Plain "Watch this video on Fly: <link>" text, used by every external
  // share destination below (WhatsApp / Messenger / Facebook / Email /
  // Copy link / More apps) — none of those write a repost, only the
  // "Share to Fly" tile above does that.
  String get _plainShareText {
    return widget.caption.isNotEmpty
        ? '${widget.caption}\n\nWatch on Fly: ${widget.videoUrl}'
        : 'Watch this video on Fly: ${widget.videoUrl}';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // Tries to open an external app via its scheme/URL. If the app isn't
  // installed (or the OS blocks the visibility check), falls back to the
  // web link inside [webFallback] so the user still gets somewhere useful.
  Future<void> _launchWithFallback(
      Uri appUri, Uri? webFallback, String appName) async {
    try {
      final bool launched =
          await launchUrl(appUri, mode: LaunchMode.externalApplication);
      if (launched) return;
    } catch (_) {
      // fall through to web fallback below
    }
    if (webFallback != null) {
      try {
        await launchUrl(webFallback, mode: LaunchMode.externalApplication);
        return;
      } catch (_) {}
    }
    _toast("Couldn't open $appName — check that it's installed");
  }

  Future<void> _shareToWhatsApp() async {
    Navigator.of(context).maybePop();
    final String text = Uri.encodeComponent(_plainShareText);
    // wa.me with no phone number opens WhatsApp's own contact/group picker,
    // so this naturally covers both individual friends and groups.
    await _launchWithFallback(
      Uri.parse('whatsapp://send?text=$text'),
      Uri.parse('https://wa.me/?text=$text'),
      'WhatsApp',
    );
  }

  Future<void> _shareToMessenger() async {
    Navigator.of(context).maybePop();
    final String link = Uri.encodeComponent(widget.videoUrl);
    // Messenger's own share dialog opens the user's friend/group list.
    await _launchWithFallback(
      Uri.parse('fb-messenger://share?link=$link'),
      Uri.parse('https://www.facebook.com/dialog/send'
          '?link=$link&app_id=0&redirect_uri=$link'),
      'Messenger',
    );
  }

  Future<void> _shareToFacebook() async {
    Navigator.of(context).maybePop();
    final String link = Uri.encodeComponent(widget.videoUrl);
    // Facebook's sharer dialog lets the user post to their feed/story or
    // send it straight to a friend, from inside the Facebook app itself.
    await _launchWithFallback(
      Uri.parse('fb://facewebmodal/f?href=https://www.facebook.com/sharer/'
          'sharer.php?u=$link'),
      Uri.parse('https://www.facebook.com/sharer/sharer.php?u=$link'),
      'Facebook',
    );
  }

  Future<void> _shareToTelegram() async {
    Navigator.of(context).maybePop();
    final String link = Uri.encodeComponent(widget.videoUrl);
    final String text = Uri.encodeComponent(_plainShareText);
    // Telegram's own share dialog opens the user's chat/group/channel list.
    await _launchWithFallback(
      Uri.parse('tg://msg_url?url=$link&text=$text'),
      Uri.parse('https://t.me/share/url?url=$link&text=$text'),
      'Telegram',
    );
  }

  Future<void> _shareToX() async {
    Navigator.of(context).maybePop();
    final String text = Uri.encodeComponent(_plainShareText);
    await _launchWithFallback(
      Uri.parse('twitter://post?message=$text'),
      Uri.parse('https://twitter.com/intent/tweet?text=$text'),
      'X',
    );
  }

  Future<void> _shareViaSms() async {
    Navigator.of(context).maybePop();
    final String body = Uri.encodeComponent(_plainShareText);
    // No recipient number - opens the phone's own contact picker, same as
    // tapping the "New message" compose button in the Messages app.
    final Uri smsUri = Uri.parse('sms:?body=$body');
    try {
      final bool launched =
          await launchUrl(smsUri, mode: LaunchMode.externalApplication);
      if (!launched) _toast("Couldn't open a messaging app");
    } catch (_) {
      _toast("Couldn't open a messaging app");
    }
  }

  Future<void> _shareViaEmail() async {
    Navigator.of(context).maybePop();
    final Uri emailUri = Uri(
      scheme: 'mailto',
      query: 'subject=${Uri.encodeComponent('Check out this video on Fly')}'
          '&body=${Uri.encodeComponent(_plainShareText)}',
    );
    try {
      final bool launched =
          await launchUrl(emailUri, mode: LaunchMode.externalApplication);
      if (!launched) _toast("Couldn't open an email app");
    } catch (_) {
      _toast("Couldn't open an email app");
    }
  }

  Future<void> _copyShareLink() async {
    await Clipboard.setData(ClipboardData(text: widget.videoUrl));
    if (mounted) Navigator.of(context).maybePop();
    _toast('Link copied to clipboard');
  }

  // Falls back to the OS's own share sheet (Telegram, SMS, Bluetooth, save
  // to Drive, and every other app installed on the phone) without going
  // through the "add a note" dialog or saving a repost.
  Future<void> _shareMoreApps() async {
    Navigator.of(context).maybePop();
    await Share.share(_plainShareText);
  }

  Future<void> _downloadVideo() async {
    Navigator.of(context).maybePop();
    _toast('Downloading video...');
    try {
      final response = await http.get(Uri.parse(widget.videoUrl));
      if (response.statusCode != 200) {
        _toast('Download failed');
        return;
      }
      final Directory tempDir = await getTemporaryDirectory();
      final String tempPath = '${tempDir.path}/'
          'fly_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final File tempFile = File(tempPath);
      await tempFile.writeAsBytes(response.bodyBytes);

      final bool hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final bool granted = await Gal.requestAccess();
        if (!granted) {
          _toast('Gallery access is needed to save the video');
          return;
        }
      }
      await Gal.putVideo(tempPath, album: 'Fly');
      await tempFile.delete();
      _toast('Video saved to your gallery');
    } catch (_) {
      _toast('Download failed — please try again');
    }
  }

  Widget _shareOptionTile(
      {required IconData icon,
      required Color color,
      required String label,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 68,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  // The main share bottom sheet: a row of direct-share destinations
  // (WhatsApp / Messenger / Facebook / Email / Copy link / More apps —
  // "More apps" opens the full OS chooser, which covers every other app
  // and lets the user pick a specific group chat inside it), plus the
  // existing in-app "Share to Fly" repost action and the video download.
  Future<void> _openShareSheet() {
    return showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Share video',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 18),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      _shareOptionTile(
                        icon: Icons.chat,
                        color: const Color(0xFF25D366),
                        label: 'WhatsApp',
                        onTap: _shareToWhatsApp,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.send,
                        color: const Color(0xFF0084FF),
                        label: 'Messenger',
                        onTap: _shareToMessenger,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.facebook,
                        color: const Color(0xFF1877F2),
                        label: 'Facebook',
                        onTap: _shareToFacebook,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.send_rounded,
                        color: const Color(0xFF29A9EA),
                        label: 'Telegram',
                        onTap: _shareToTelegram,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.close,
                        color: Colors.black,
                        label: 'X',
                        onTap: _shareToX,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.sms,
                        color: const Color(0xFF34C759),
                        label: 'Text',
                        onTap: _shareViaSms,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.email,
                        color: Colors.orangeAccent,
                        label: 'Email',
                        onTap: _shareViaEmail,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.link,
                        color: Colors.grey.shade700,
                        label: 'Copy link',
                        onTap: _copyShareLink,
                      ),
                      const SizedBox(width: 14),
                      _shareOptionTile(
                        icon: Icons.apps,
                        color: Colors.grey.shade700,
                        label: 'More apps',
                        onTap: _shareMoreApps,
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(color: Colors.white24, height: 1),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Colors.redAccent,
                    child: Icon(Icons.flight, color: Colors.white, size: 18),
                  ),
                  title: const Text('Share to Fly',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Repost this on your own profile',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _shareVideo();
                  },
                ),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.grey.shade800,
                    child: const Icon(Icons.download,
                        color: Colors.white, size: 18),
                  ),
                  title: const Text('Download video',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Save to your phone gallery',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  onTap: _downloadVideo,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Live count of a post subcollection (comments / shares / saves)
  Stream<QuerySnapshot> _postSubStream(String sub) {
    return FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection(sub)
        .snapshots();
  }

  // Saves or unsaves this post (stored per-post so the total can be counted)
  Future<void> _toggleSave(bool isSaved) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || widget.postId.isEmpty) return;

    final ref = FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection('saves')
        .doc(user.uid);
    // Also kept in the saver's own private list, users/{uid}/saved/
    // {postId}, which is what the "Saved" screen (saved_videos_screen.dart)
    // reads - a plain per-user query with no extra Firestore index, instead
    // of searching every post's `saves` subcollection. Both docs are
    // written in one batch so they never disagree.
    final myListRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('saved')
        .doc(widget.postId);
    try {
      final batch = FirebaseFirestore.instance.batch();
      if (isSaved) {
        batch.delete(ref);
        batch.delete(myListRef);
      } else {
        batch.set(ref, {
          'uid': user.uid,
          'ownerId': widget.userId,
          'videoUrl': widget.videoUrl,
          'caption': widget.caption,
          'videoType': widget.videoType,
          'savedAt': FieldValue.serverTimestamp(),
        });
        batch.set(myListRef, {
          'postId': widget.postId,
          'ownerId': widget.userId,
          'videoUrl': widget.videoUrl,
          'savedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    } catch (_) {
      // Ignore save errors so the UI is never blocked.
    }
  }

  // Formats counts like 17300 -> "17.3K", 2400000 -> "2.4M"
  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  // Small count text shown under each action icon
  Widget _countLabel(String text) {
    return Padding(
      // Sits close under its icon, like Facebook Reels' counts.
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
        ),
      ),
    );
  }

  void _openComments() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _CommentsSheet(
        postId: widget.postId,
        ownerId: widget.userId,
        highlightUserId: widget.highlightCommentFrom,
        highlightText: widget.highlightCommentText,
        highlightCommentId: widget.highlightCommentId,
      ),
    );
  }

  @override
  void dispose() {
    flyRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _processingRetryTimer?.cancel();
    _stallTimer?.cancel();
    _controller?.removeListener(_onVideoProgress);
    _controller?.dispose();
    _controlsVisible.dispose();
    _muted.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // The whole post item listens directly to its own Firestore document.
    // This is what keeps the like count and my-reaction state ALWAYS in
    // sync with the database, instead of depending on the parent post-list
    // snapshot (which could be a tick behind and made counts look wrong or
    // jump around, and made double-tapping like feel unreliable).
    return StreamBuilder<DocumentSnapshot>(
      stream: _postDocStream,
      builder: (context, postSnap) {
        final Map<String, dynamic>? livePostData =
            (postSnap.data?.data()) as Map<String, dynamic>?;
        // Fall back to the reactions passed in from the list while the
        // document stream is still loading its first snapshot.
        final Map<String, dynamic> liveReactions =
            (livePostData?['reactions'] as Map<String, dynamic>?) ??
                widget.reactions;
        final String? myReaction =
            user != null ? liveReactions[user.uid] as String? : null;

        // Which sound this video uses, so it can be credited and opened.
        final String? soundId = livePostData?['soundId'] as String?;
        final String soundLabel = [
          (livePostData?['soundTitle'] as String?) ?? 'Original sound',
          (livePostData?['soundOwnerName'] as String?) ?? '',
        ].where((s) => s.isNotEmpty).join(' - ');

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleScreenTap,
          onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
          onDoubleTap: () => _onDoubleTapLike(liveReactions),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_isInitialized && _controller != null) ...[
                if (widget.repostByName != null &&
                    widget.repostByName!.isNotEmpty)
                  // Reposts show the original video inside a framed box
                  // (not edge-to-edge), so it visually reads as "this
                  // person's video", clearly separate from the sharer's
                  // own header above it.
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 30,
                    left: 8,
                    right: 8,
                    bottom: 130,
                    child: GestureDetector(
                      // Tapping the framed video jumps to the original
                      // post's own page (not the repost wrapper), so it
                      // reads like "go see this video where it lives".
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SingleVideoScreen(
                              postId: widget.postId,
                              userId: widget.userId,
                              videoUrl: widget.videoUrl,
                              caption: widget.caption,
                              userEmail: widget.userEmail,
                              videoType: widget.videoType,
                            ),
                          ),
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.white.withOpacity(0.3),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(15),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _withOptionalFilter(
                                  FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: _controller!.value.size.width,
                                      height: _controller!.value.size.height,
                                      child: VideoPlayer(_controller!),
                                    ),
                                  ),
                                ),
                                if (!widget.effectsBaked)
                                  for (final overlay in widget.textOverlays)
                                    _positionedOverlayText(overlay),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                else ...[
                  // "Smart Fit": compare the video's own shape to the
                  // phone's screen shape. When they're close (a normal
                  // vertical video on a normal vertical phone), fill the
                  // screen edge-to-edge - the sliver that gets cropped off
                  // is barely noticeable. When they're very different (a
                  // landscape recording, a square video), show the video
                  // in full instead, with plain black behind it, rather
                  // than cropping away a big chunk of what was actually
                  // filmed.
                  Builder(builder: (context) {
                    final Size screenSize = MediaQuery.of(context).size;
                    final double screenRatio =
                        screenSize.width / screenSize.height;
                    final double videoRatio = _controller!.value.aspectRatio;
                    final double mismatch = videoRatio > screenRatio
                        ? videoRatio / screenRatio
                        : screenRatio / videoRatio;
                    final bool shouldCover = mismatch < 1.35;

                    final Widget videoContent = shouldCover
                        ? FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: _controller!.value.size.width,
                              height: _controller!.value.size.height,
                              child: _withOptionalFilter(
                                  VideoPlayer(_controller!)),
                            ),
                          )
                        : Stack(
                            children: [
                              Container(color: Colors.black),
                              Center(
                                child: AspectRatio(
                                  aspectRatio: videoRatio,
                                  child: _withOptionalFilter(
                                      VideoPlayer(_controller!)),
                                ),
                              ),
                            ],
                          );

                    // Leave room at the bottom for the caption/profile
                    // panel below - the video fills the screen only down
                    // to where that panel starts, not underneath it.
                    return Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      bottom: _kCaptionPanelHeight,
                      child: ClipRect(child: videoContent),
                    );
                  }),
                  if (!widget.effectsBaked)
                    for (final overlay in widget.textOverlays)
                      _positionedOverlayText(overlay),
                  // Until the first frame is actually on screen (and while
                  // the stream rebuffers), keep the thumbnail + a small
                  // spinner up instead of a bare black screen.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    bottom: _kCaptionPanelHeight,
                    child: IgnorePointer(
                      child: _FirstFrameCover(
                        controller: _controller!,
                        thumbUrl: cloudinaryThumbUrl(widget.videoUrl),
                      ),
                    ),
                  ),
                ],
              ] else
                Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.videoUrl.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: cloudinaryThumbUrl(widget.videoUrl),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey[900]),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey[900]),
                      ),
                    if (_hasError)
                      // Couldn't load (timed out / no connection) - a
                      // spinner with no way out is worse than telling the
                      // person plainly what happened, so this replaces the
                      // spinner rather than layering on top of it.
                      Center(
                        child: GestureDetector(
                          onTap: _retryVideoLoad,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.wifi_off_rounded,
                                    color: Colors.white, size: 30),
                                SizedBox(height: 8),
                                Text(
                                  "Couldn't load - tap to retry",
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else if (_isProcessing)
                      // Just uploaded - Bunny is still encoding. Retries
                      // automatically (see _scheduleProcessingRetry), so
                      // there's nothing to tap here.
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 16),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  color: Color(0xFFFF4B6E),
                                  strokeWidth: 2.5,
                                ),
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Processing video...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'It will play automatically when ready',
                                style: TextStyle(
                                    color: Colors.white60, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      // Only after a short wait: a hand-over from Home to
                      // full-screen (or a quick start) never flashes it.
                      const _FeedDelayedSpinner(),
                  ],
                ),

              // Tap-to-reveal media controls: rewind 10s / play-pause / forward 10s.
              // No full-screen dim (each button has its own dark circle) so toggling
              // the controls never flickers the like button / profile behind them.
              ValueListenableBuilder<bool>(
                valueListenable: _controlsVisible,
                builder: (context, visible, _) {
                  final c = _controller;
                  if (!visible || !_isInitialized || c == null) {
                    return const SizedBox.shrink();
                  }
                  final double bottomInset =
                      MediaQuery.of(context).padding.bottom;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _circleControl(
                              icon: Icons.replay_10,
                              diameter: 58,
                              iconSize: 30,
                              onTap: () => _seekBy(-10),
                            ),
                            _circleControl(
                              icon: c.value.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              diameter: 74,
                              iconSize: 44,
                              onTap: _togglePlayPause,
                            ),
                            _circleControl(
                              icon: Icons.forward_10,
                              diameter: 58,
                              iconSize: 30,
                              onTap: () => _seekBy(10),
                            ),
                          ],
                        ),
                      ),
                      // Bottom control bar: time / duration, scrub slider, mute
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 4 + bottomInset,
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: c,
                          builder: (context, value, __) {
                            final Duration pos = value.position;
                            final Duration dur = value.duration;
                            final double maxMs = dur.inMilliseconds <= 0
                                ? 1.0
                                : dur.inMilliseconds.toDouble();
                            double curMs = pos.inMilliseconds.toDouble();
                            if (curMs < 0) curMs = 0;
                            if (curMs > maxMs) curMs = maxMs;

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  child: Row(
                                    children: [
                                      Text(
                                        _fmtDuration(pos),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          shadows: [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 6)
                                          ],
                                        ),
                                      ),
                                      Text(
                                        ' / ${_fmtDuration(dur)}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          shadows: [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 6)
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      ValueListenableBuilder<bool>(
                                        valueListenable: _muted,
                                        builder: (context, muted, ___) {
                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: _toggleMute,
                                            child: Padding(
                                              padding: const EdgeInsets.all(4),
                                              child: Icon(
                                                muted
                                                    ? Icons.volume_off_rounded
                                                    : Icons.volume_up_rounded,
                                                color: Colors.white,
                                                size: 24,
                                                shadows: const [
                                                  Shadow(
                                                      color: Colors.black,
                                                      blurRadius: 6)
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                SliderTheme(
                                  data: SliderThemeData(
                                    trackHeight: 3,
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white30,
                                    thumbColor: Colors.white,
                                    overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 14),
                                    thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 7),
                                  ),
                                  child: Slider(
                                    value: curMs,
                                    min: 0,
                                    max: maxMs,
                                    onChanged: (v) {
                                      c.seekTo(
                                          Duration(milliseconds: v.toInt()));
                                    },
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),

              if (widget.repostByName != null &&
                  widget.repostByName!.isNotEmpty)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 4,
                  left: 16,
                  right: 90,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (widget.repostByUserId == null ||
                              widget.repostByUserId!.isEmpty) {
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PublicProfileScreen(
                                userId: widget.repostByUserId!,
                              ),
                            ),
                          );
                        },
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 13,
                              backgroundColor: Colors.grey[850],
                              backgroundImage: (widget.repostByPhoto != null &&
                                      widget.repostByPhoto!.isNotEmpty)
                                  ? NetworkImage(widget.repostByPhoto!)
                                  : null,
                              child: (widget.repostByPhoto == null ||
                                      widget.repostByPhoto!.isEmpty)
                                  ? Text(
                                      widget.repostByName!.isNotEmpty
                                          ? widget.repostByName![0]
                                              .toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: widget.repostByName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        shadows: [
                                          Shadow(
                                              color: Colors.black54,
                                              blurRadius: 6),
                                        ],
                                      ),
                                    ),
                                    const TextSpan(text: ' shared this'),
                                  ],
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  shadows: [
                                    Shadow(
                                        color: Colors.black54, blurRadius: 6),
                                  ],
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.repostNote != null &&
                          widget.repostNote!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          widget.repostNote!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 6),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

              // A solid black panel of its own for the caption/username/
              // sound row - not just text floating over the video with a
              // shadow, but its own distinctly separate area underneath
              // (the video above is sized to leave exactly this much
              // room, see the Smart Fit Builder above).
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _kCaptionPanelHeight,
                child: IgnorePointer(
                  child: Container(
                    color: const Color(0xFF000000),
                  ),
                ),
              ),

              Positioned(
                left: 16,
                bottom: 100,
                right: 90,
                child: (widget.repostByName != null &&
                        widget.repostByName!.isNotEmpty)
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.25),
                            width: 0.6,
                          ),
                        ),
                        child: _OwnerInfo(
                          userId: widget.userId,
                          fallbackEmail: widget.userEmail,
                          caption: widget.caption,
                          postId: widget.postId,
                          soundId: soundId,
                          soundLabel: soundLabel,
                          reactionCount: liveReactions.length,
                          replyToPostId:
                              livePostData?['replyToPostId'] as String?,
                          replyToOwnerId:
                              livePostData?['replyToOwnerId'] as String?,
                          replyToOwnerName:
                              livePostData?['replyToOwnerName'] as String?,
                          compact: true,
                        ),
                      )
                    : _OwnerInfo(
                        userId: widget.userId,
                        fallbackEmail: widget.userEmail,
                        caption: widget.caption,
                        postId: widget.postId,
                        soundId: soundId,
                        soundLabel: soundLabel,
                        reactionCount: liveReactions.length,
                        replyToPostId:
                            livePostData?['replyToPostId'] as String?,
                        replyToOwnerId:
                            livePostData?['replyToOwnerId'] as String?,
                        replyToOwnerName:
                            livePostData?['replyToOwnerName'] as String?,
                      ),
              ),

              // Double-tap hearts, centred on the finger.
              ..._tapHearts.map((h) {
                return Positioned(
                  left: h.pos.dx - 55,
                  top: h.pos.dy - 55,
                  child: IgnorePointer(
                    child: _DoubleTapHeart(
                      key: ValueKey(h.id),
                      onDone: () {
                        _tapHearts.removeWhere((x) => x.id == h.id);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                );
              }),

              ..._flyingEmojis.map((e) {
                return Positioned(
                  right: 30,
                  bottom: 140,
                  child: _FlyingEmojiWidget(
                    key: ValueKey(e.id),
                    data: e,
                    onComplete: () => _removeFlyingEmoji(e.id),
                  ),
                );
              }),

              if (_showReactionPicker)
                Positioned(
                  right: 12,
                  bottom: 180,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: kReactions.entries.map((entry) {
                            final int i =
                                kReactions.keys.toList().indexOf(entry.key);
                            return _AnimatedEmoji(
                              emoji: entry.value,
                              delayMs: i * 90,
                              onTap: () =>
                                  _setReaction(entry.key, liveReactions),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),

              if (widget.repostByName == null || widget.repostByName!.isEmpty)
                Positioned(
                  right: 12,
                  bottom: 120,
                  // Fly's action dock: Like/Comment/Share/Save float
                  // directly over the video (no background panel), each with
                  // a soft glow chip that lights up when active. Compact,
                  // Facebook-Reels-like rhythm: 46x40 tap boxes, counts 2px
                  // under the icon, 6px between buttons, 28px white-outline
                  // comment/share icons. (12px gaps + 46px-tall boxes were
                  // tried first and looked too spread out on Ko's phone.)
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Like (long-press for reactions)
                      GestureDetector(
                        onTap: () => _quickToggleLike(liveReactions),
                        onLongPress: () =>
                            setState(() => _showReactionPicker = true),
                        child: Column(
                          children: [
                            _FlyActionGlow(
                              active: myReaction != null,
                              child: SizedBox(
                                width: 46,
                                height: 40,
                                child: Center(
                                  child: myReaction == 'like'
                                      ? const _PopInLikeBadge(
                                          key: ValueKey('like'),
                                          diameter: 40,
                                        )
                                      : myReaction != null
                                          ? _PopInEmoji(
                                              key: ValueKey(myReaction),
                                              emoji: kReactions[myReaction]!,
                                            )
                                          : const Icon(
                                              Icons.favorite,
                                              color: Colors.white,
                                              size: 32,
                                              shadows: [
                                                Shadow(
                                                    color: Colors.black,
                                                    blurRadius: 8),
                                              ],
                                            ),
                                ),
                              ),
                            ),
                            _countLabel(_formatCount(liveReactions.length)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Comment
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('comments'),
                        builder: (context, snap) {
                          // Comments the video owner hid aren't counted.
                          final int count = snap.hasData
                              ? _visibleCommentCount(snap.data!.docs)
                              : 0;
                          return GestureDetector(
                            onTap: _openComments,
                            child: Column(
                              children: [
                                _FlyActionGlow(
                                  active: false,
                                  child: SizedBox(
                                    width: 46,
                                    height: 40,
                                    child: Center(
                                      child: _FlyCommentIcon(size: 28),
                                    ),
                                  ),
                                ),
                                _countLabel(_formatCount(count)),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      // Share
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('shares'),
                        builder: (context, snap) {
                          final int count =
                              snap.hasData ? snap.data!.docs.length : 0;
                          return GestureDetector(
                            onTap: _openShareSheet,
                            child: Column(
                              children: [
                                _FlyActionGlow(
                                  active: false,
                                  child: SizedBox(
                                    width: 46,
                                    height: 40,
                                    child: Center(
                                      child: _FlySwooshShareIcon(size: 28),
                                    ),
                                  ),
                                ),
                                _countLabel(_formatCount(count)),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      // Save / bookmark
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('saves'),
                        builder: (context, snap) {
                          final myId = FirebaseAuth.instance.currentUser?.uid;
                          final docs =
                              snap.hasData ? snap.data!.docs : const [];
                          final int count = docs.length;
                          final bool isSaved =
                              myId != null && docs.any((d) => d.id == myId);
                          return GestureDetector(
                            onTap: () => _toggleSave(isSaved),
                            child: Column(
                              children: [
                                _FlyActionGlow(
                                  active: isSaved,
                                  child: SizedBox(
                                    width: 46,
                                    height: 40,
                                    child: Center(
                                      child: Icon(
                                        isSaved
                                            ? Icons.bookmark
                                            : Icons.bookmark_border,
                                        color: Colors.white,
                                        size: 30,
                                        shadows: const [
                                          Shadow(
                                              color: Colors.black,
                                              blurRadius: 8),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                _countLabel(_formatCount(count)),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                      // More options (Report / Block)
                      GestureDetector(
                        onTap: () => _showReportBlockSheet(context),
                        child: _FlyActionGlow(
                          active: false,
                          child: const SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                              child: Icon(
                                Icons.more_horiz,
                                color: Colors.white,
                                size: 26,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 8),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Reposts show like/comment/share as a compact horizontal row
              // under the boxed video (Facebook-style) instead of the
              // vertical right-side rail used for regular posts.
              if (widget.repostByName != null &&
                  widget.repostByName!.isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 46,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => _quickToggleLike(liveReactions),
                        onLongPress: () =>
                            setState(() => _showReactionPicker = true),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              myReaction != null
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: myReaction != null
                                  ? const Color(0xFFFF4B6E)
                                  : Colors.white,
                              size: 20,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 6)
                              ],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatCount(liveReactions.length),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 6)
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 18),
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('comments'),
                        builder: (context, snap) {
                          // Comments the video owner hid aren't counted.
                          final int count = snap.hasData
                              ? _visibleCommentCount(snap.data!.docs)
                              : 0;
                          return GestureDetector(
                            onTap: _openComments,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  color: Colors.white,
                                  size: 19,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 6)
                                  ],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _formatCount(count),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    shadows: [
                                      Shadow(color: Colors.black, blurRadius: 6)
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 18),
                      StreamBuilder<QuerySnapshot>(
                        stream: _postSubStream('shares'),
                        builder: (context, snap) {
                          final int count =
                              snap.hasData ? snap.data!.docs.length : 0;
                          return GestureDetector(
                            onTap: _openShareSheet,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Transform.flip(
                                  flipX: true,
                                  child: const Icon(
                                    Icons.reply,
                                    color: Colors.white,
                                    size: 20,
                                    shadows: [
                                      Shadow(color: Colors.black, blurRadius: 6)
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _formatCount(count),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    shadows: [
                                      Shadow(color: Colors.black, blurRadius: 6)
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _showReportBlockSheet(context),
                        child: const Icon(
                          Icons.more_horiz,
                          color: Colors.white,
                          size: 22,
                          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                        ),
                      ),
                    ],
                  ),
                ),
              // "Fly Frame": a small cinematic-style black band top and
              // bottom, each with a thin glowing cyan line right at the
              // screen edge - Fly's own branded framing instead of plain
              // flat black, and it also keeps the status bar clock and
              // the phone's (now-transparent) gesture/nav bar icons easy
              // to read over whatever's playing underneath. The video's
              // own size/fit is untouched - this sits on top of it, not
              // cut out of it. Positioned (not Align+Container) so the
              // bar's width is pinned unambiguously edge-to-edge.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 34,
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(0.85),
                              Colors.black.withOpacity(0.0),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 1.4,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFF35E1E8).withOpacity(0.0),
                                const Color(0xFF35E1E8).withOpacity(0.55),
                                const Color(0xFF5B7CFA).withOpacity(0.55),
                                const Color(0xFF35E1E8).withOpacity(0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 34,
                child: IgnorePointer(
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withOpacity(0.85),
                              Colors.black.withOpacity(0.0),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 1.4,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFF35E1E8).withOpacity(0.0),
                                const Color(0xFF35E1E8).withOpacity(0.55),
                                const Color(0xFF5B7CFA).withOpacity(0.55),
                                const Color(0xFF35E1E8).withOpacity(0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Looks up a user's display name for the "Replying to @X" banner, since
  // _VideoPostItem only has their uid, not their display name, on hand.
  Future<String> _fetchDisplayName(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final String? name = doc.data()?['displayName'] as String?;
      return (name != null && name.trim().isNotEmpty) ? name : 'user';
    } catch (_) {
      return 'user';
    }
  }

  // Shows a bottom sheet with "Report" (always) and "Block user" (only for
  // other people's posts) options.
  void _showReportBlockSheet(BuildContext context) {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    final bool isOwnPost = myId != null && myId == widget.userId;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.white),
                title: const Text('Report post',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showReportReasonSheet(
                    targetType: 'post',
                    targetId: widget.postId,
                    targetOwnerId: widget.userId,
                  );
                },
              ),
              if (!isOwnPost)
                ListTile(
                  leading: const Icon(Icons.reply, color: Color(0xFF35E1F2)),
                  title: const Text('Reply with video',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final String replyOwnerName =
                        await _fetchDisplayName(widget.userId);
                    if (!context.mounted) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => UploadScreen(
                          replyToPostId: widget.postId,
                          replyToOwnerId: widget.userId,
                          replyToOwnerName: replyOwnerName,
                        ),
                      ),
                    );
                  },
                ),
              if (!isOwnPost)
                ListTile(
                  leading: const Icon(Icons.block, color: Colors.redAccent),
                  title: const Text('Block user',
                      style: TextStyle(color: Colors.redAccent)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _confirmBlockUser(widget.userId);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // Shows the reason picker, then writes a 'reports' document.
  void _showReportReasonSheet({
    required String targetType, // 'post' or 'comment'
    required String targetId,
    required String targetOwnerId,
    String? parentPostId, // set when targetType == 'comment'
  }) {
    const List<String> reasons = [
      'Nudity or sexual content',
      'Hate speech or harassment',
      'Violence or dangerous content',
      'Spam or scam',
      'Something else',
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Why are you reporting this?',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
              ...reasons.map((reason) => ListTile(
                    title: Text(reason,
                        style: const TextStyle(color: Colors.white70)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _submitReport(
                        targetType: targetType,
                        targetId: targetId,
                        targetOwnerId: targetOwnerId,
                        reason: reason,
                        parentPostId: parentPostId,
                      );
                    },
                  )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _submitReport({
    required String targetType,
    required String targetId,
    required String targetOwnerId,
    required String reason,
    String? parentPostId,
  }) async {
    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'targetType': targetType,
        'targetId': targetId,
        'parentPostId': parentPostId,
        'targetOwnerId': targetOwnerId,
        'reporterId': myId,
        'reason': reason,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted. Thank you.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not submit report. Try again.')),
        );
      }
    }
  }

  Future<void> _confirmBlockUser(String userIdToBlock) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Block this user?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          "You won't see their posts or comments anymore, and they won't be "
          'able to message you.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Block', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final String? myId = FirebaseAuth.instance.currentUser?.uid;
    if (myId == null) return;

    try {
      // Both directions + unfollow (see block_service.dart).
      await BlockService.instance.block(userIdToBlock);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User blocked.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not block user. Try again.')),
        );
      }
    }
  }
}

// The big heart a double-tap pops on the video (15 Oct 2026): springs in
// with a slight random tilt, floats up a little and fades out (~0.8s),
// then calls [onDone] so the video post removes it.
class _DoubleTapHeart extends StatefulWidget {
  final VoidCallback onDone;
  const _DoubleTapHeart({super.key, required this.onDone});

  @override
  State<_DoubleTapHeart> createState() => _DoubleTapHeartState();
}

class _DoubleTapHeartState extends State<_DoubleTapHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..forward().whenComplete(() => widget.onDone());
  final double _tilt = (Random().nextDouble() - 0.5) * 0.6;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final double t = _c.value;
        // 0 -> 0.25: spring in (overshoots a little); then hold and fade.
        final double scale = t < 0.25
            ? Curves.easeOutBack.transform(t / 0.25) * 1.15
            : 1.15 - (t - 0.25) * 0.3;
        final double opacity = t < 0.6 ? 1.0 : (1 - (t - 0.6) / 0.4);
        return Transform.translate(
          offset: Offset(0, -30 * t),
          child: Transform.rotate(
            angle: _tilt,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: scale,
                child: const SizedBox(
                  width: 110,
                  height: 110,
                  child: Icon(
                    Icons.favorite,
                    size: 100,
                    color: Color(0xFFFF2D55),
                    shadows: [Shadow(color: Colors.black38, blurRadius: 12)],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// The feed's loading spinner, shown only after a short delay so a start
// that takes a moment (or a player hand-over between screens) doesn't
// flash a spinner for a split second.
class _FeedDelayedSpinner extends StatefulWidget {
  const _FeedDelayedSpinner();

  @override
  State<_FeedDelayedSpinner> createState() => _FeedDelayedSpinnerState();
}

class _FeedDelayedSpinnerState extends State<_FeedDelayedSpinner> {
  static const Duration _delay = Duration(milliseconds: 900);
  Timer? _timer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          color: Colors.white,
          strokeWidth: 2.5,
        ),
      ),
    );
  }
}
