import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/brand_paths.dart';
import 'package:gatomix/core/id3_names.dart';
import 'package:gatomix/core/lyric_files.dart';
import 'package:gatomix/core/lyric_match.dart';

void main() {
  test('ID3 manda y el nombre de archivo solo rellena lo que falta', () {
    final LyricIdentity diana = lyricIdentity(
      path: r'C:\music\Diana Ross.mp3',
      id3Artist: 'Diana Ross',
      id3Title: 'Upside Down',
      id3Album: 'diana',
      durationSec: 254,
    );
    expect(diana.artist, 'Diana Ross');
    expect(diana.title, 'Upside Down');
    expect(diana.album, 'diana');
    expect(diana.remixOrExtended, isFalse);

    final LyricIdentity soloNombre = lyricIdentity(
      path: 'Diana Ross.mp3',
      durationSec: 254,
    );
    expect(soloNombre.title, 'Diana Ross');
    expect(soloNombre.artist, isEmpty);

    final LyricIdentity toma = lyricIdentity(
      path: '85 Bpm - a-ha - Take On Me.mp3',
      durationSec: 223,
    );
    expect(toma.artist, 'a-ha');
    expect(toma.title, 'Take On Me');

    final Uri get = lrclibGetUri(diana);
    expect(get.path, '/api/get');
    expect(get.queryParameters['artist_name'], 'Diana Ross');
    expect(get.queryParameters['track_name'], 'Upside Down');
    expect(get.queryParameters['album_name'], 'diana');
    expect(get.queryParameters['duration'], '254');
    expect(lrclibSearchUri(diana).queryParameters.containsKey('q'), isFalse);
  });

  test('TALB se lee junto con el título y el artista', () {
    final Id3Names names = parseId3Names(
      _id3v23(title: 'Upside Down', artist: 'Diana Ross', album: 'diana'),
    );
    expect(names.title, 'Upside Down');
    expect(names.artist, 'Diana Ross');
    expect(names.album, 'diana');
  });

  test('Diana Ross no se queda con Thank You', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Diana Ross.mp3',
      id3Artist: 'Diana Ross',
      id3Title: 'Upside Down',
      id3Album: 'diana',
      durationSec: 254,
    );
    final LyricChoice soloMal = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Diana Ross',
        title: 'Thank You',
        duration: 254,
        synced: _lrc(<(int, String)>[(11, 'Thank You'), (219, 'Thank You')]),
      )],
    );
    expect(soloMal.kind, LyricKind.none);

    final LyricChoice conLaBuena = chooseLrclibLyric(
      id,
      searched: [
        _hit(
          artist: 'Diana Ross',
          title: 'Thank You',
          duration: 254,
          synced: _lrc(<(int, String)>[(11, 'Thank You'), (219, 'Thank You')]),
        ),
        _hit(
          artist: 'Diana Ross',
          title: 'Upside Down',
          duration: 254,
          synced: _lrc(<(int, String)>[(17, 'Upside Down'), (240, 'Upside Down')]),
        ),
      ],
    );
    expect(conLaBuena.kind, LyricKind.synced);
    expect(conLaBuena.body, contains('Upside Down'));
    expect(conLaBuena.body, isNot(contains('Thank You')));
  });

  test('Samantha Fox no se queda con Forever', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Samantha Fox.mp3',
      id3Artist: 'Samantha Fox',
      id3Title: 'Touch Me',
      durationSec: 226,
    );
    final String forever = _stamp(30, 'Forever') + _stamp(263, 'Forever');
    final LyricChoice mal = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Samantha Fox',
        title: 'Forever feat Samantha Fox',
        duration: 263,
        synced: forever,
      )],
    );
    expect(mal.kind, LyricKind.none);
    expect(mal.body, isNot(contains('Forever')));

    final LyricChoice bien = chooseLrclibLyric(
      id,
      searched: [
        _hit(
          artist: 'Samantha Fox',
          title: 'Forever feat Samantha Fox',
          duration: 263,
          synced: forever,
        ),
        _hit(
          artist: 'Samantha Fox',
          title: 'Touch Me (I Want Your Body)',
          duration: 226,
          synced: _lrc(<(int, String)>[(2, 'Touch Me'), (220, 'Touch Me')]),
        ),
      ],
    );
    expect(bien.kind, LyricKind.synced);
    expect(bien.body, contains('Touch Me'));
    expect(bien.fileText, isNot(contains('Forever')));
  });

  test('el remix de Blondie no hereda la edición de radio', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Blondie - Call Me (Remix).mp3',
      durationSec: 469,
    );
    expect(id.remixOrExtended, isTrue);
    expect(id.title, 'Call Me (Remix)');
    final String radio = _stamp(15, 'Call me') + _stamp(206, 'RADIO');
    final LyricChoice soloRadio = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Blondie',
        title: 'Call Me',
        duration: 208,
        synced: radio,
        plain: 'Call me on the line',
      )],
    );
    expect(soloRadio.kind, isNot(LyricKind.synced));
    expect(soloRadio.fileText, isNot(contains('RADIO')));
    expect(soloRadio.fileText, isNot(contains('[03:')));
    expect(soloRadio.kind, LyricKind.plain);

    final LyricChoice sinPlana = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Blondie',
        title: 'Call Me',
        duration: 208,
        synced: radio,
      )],
    );
    expect(sinPlana.kind, LyricKind.none);
  });

  test('Glenn no hereda la edición de radio', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Glenn Frey - The Heat Is On.mp3',
      durationSec: 363,
    );
    expect(id.remixOrExtended, isFalse);
    final String radio = _stamp(21, 'The heat') + _stamp(220, 'RADIO');
    final LyricChoice honesta = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Glenn Frey',
        title: 'The Heat Is On',
        duration: 220,
        synced: radio,
        plain: 'The heat is on',
      )],
    );
    expect(honesta.kind, LyricKind.none);

    final LyricChoice duracionMiente = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Glenn Frey',
        title: 'The Heat Is On',
        duration: 363,
        synced: radio,
      )],
    );
    expect(duracionMiente.kind, LyricKind.none);
    expect(duracionMiente.body, isNot(contains('RADIO')));
  });

  test('Hello y Take On Me coinciden', () {
    final LyricIdentity hello = lyricIdentity(
      path: 'Lionel Richie - Hello.mp3',
      durationSec: 242,
    );
    final LyricChoice helloHit = chooseLrclibLyric(
      hello,
      direct: _hit(
        artist: 'Lionel Richie',
        title: 'Hello',
        album: 'Can\'t Slow Down',
        duration: 242,
        synced: _stamp(16, 'Hello') + _stamp(224, 'Hello'),
      ),
    );
    expect(helloHit.kind, LyricKind.synced);
    expect(helloHit.body, contains('Hello'));

    final LyricIdentity toma = lyricIdentity(
      path: 'a-ha - Take On Me.mp3',
      durationSec: 223,
    );
    final LyricChoice tomaHit = chooseLrclibLyric(
      toma,
      searched: [_hit(
        artist: 'a-ha',
        title: 'Take On Me',
        duration: 223,
        synced: _stamp(34, 'Take on me') + _stamp(220, 'Take on me'),
      )],
    );
    expect(tomaHit.kind, LyricKind.synced);
    expect(tomaHit.body, contains('Take on me'));
  });

  test('duración ±2 s y la última línea a ≤ 20 s del final', () {
    final LyricIdentity id = lyricIdentity(
      path: 'a-ha - Take On Me.mp3',
      durationSec: 223,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 225,
          synced: _stamp(30, 'a') + _stamp(221, 'b'),
        ),
      ).kind,
      LyricKind.synced,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 226,
          synced: _stamp(30, 'a') + _stamp(221, 'b'),
        ),
      ).kind,
      LyricKind.synced,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 234,
          synced: _stamp(30, 'a') + _stamp(221, 'b'),
        ),
      ).kind,
      LyricKind.none,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 223,
          synced: _stamp(30, 'a') + _stamp(203, 'b'),
        ),
      ).kind,
      LyricKind.synced,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 223,
          synced: _stamp(30, 'a') + _stamp(202, 'b'),
        ),
      ).kind,
      LyricKind.none,
    );
    expect(
      lrcEndsWithAudio(_stamp(30, 'a') + _stamp(263, 'b'), 226),
      isFalse,
    );
  });

  test('un .lrc que ya existe no se vuelve a bajar', () {
    expect(lyricMayDownload(lrcExists: true), isFalse);
    expect(lyricMayDownload(lrcExists: false), isTrue);
  });

  test('Unknown y ReGenial Master no se envían: entra el archivo', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Duncan Dhu - A Un Minuto.mp3',
      id3Artist: 'Unknown',
      id3Title: 'Desconocido',
      id3Album: 'ReGenial Master',
      durationSec: 214,
    );
    expect(id.artist, 'Duncan Dhu');
    expect(id.title, 'A Un Minuto');
    expect(id.album, isEmpty);
    expect(lrclibGetUri(id).queryParameters.containsKey('album_name'), isFalse);
    expect(repairLyricText('AÃ±os'), 'Años');
    expect(repairLyricText('mINUTO'), 'Minuto');
    expect(lyricNorm('AÃ±os'), lyricNorm('Años'));
  });

  test('Duncan Dhu y Medardo coinciden por alias y contención', () {
    final LyricIdentity duncan = lyricIdentity(
      path: 'Duncan Dhu - A Un Minuto.mp3',
      durationSec: 214,
    );
    final LyricChoice hit = chooseLrclibLyric(
      duncan,
      searched: [
        _hit(
          artist: 'MIKEL ERENTXUN (DUNCAN DHU)',
          title: 'A Un Minuto',
          duration: 215,
          synced: _stamp(12, 'A un minuto') + _stamp(200, 'A un minuto'),
        ),
      ],
    );
    expect(hit.kind, LyricKind.synced);
    expect(hit.body, contains('A un minuto'));

    final LyricIdentity medardo = lyricIdentity(
      path: 'Medardo.mp3',
      id3Artist: 'Medardo',
      id3Title: 'Cumbia',
      durationSec: 180,
    );
    expect(
      lyricArtistsMatch('Medardo', 'Don Medardo y Sus Players'),
      isTrue,
    );
    final LyricChoice cumbia = chooseLrclibLyric(
      medardo,
      searched: [
        _hit(
          artist: 'Don Medardo y Sus Players',
          title: 'Cumbia',
          duration: 181,
          synced: _stamp(8, 'Cumbia') + _stamp(170, 'Cumbia'),
        ),
      ],
    );
    expect(cumbia.kind, LyricKind.synced);
  });

  test('si el ID3 contradice al archivo, gana la duración del nombre', () {
    final List<LyricIdentity> ids = lyricIdentities(
      path: 'Diana Ross - Upside Down.mp3',
      id3Artist: 'Diana Ross',
      id3Title: 'Thank You',
      durationSec: 254,
    );
    expect(ids, hasLength(2));
    expect(ids.last.fromFile, isTrue);
    final LyricChoice choice = chooseLrclibLyric(
      ids.first,
      also: ids.sublist(1),
      searched: [
        _hit(
          artist: 'Diana Ross',
          title: 'Thank You',
          duration: 254,
          synced: _lrc(<(int, String)>[(11, 'Thank You'), (240, 'Thank You')]),
        ),
        _hit(
          artist: 'Diana Ross',
          title: 'Upside Down',
          duration: 254,
          synced: _lrc(<(int, String)>[(17, 'Upside Down'), (240, 'Upside Down')]),
        ),
      ],
    );
    expect(choice.kind, LyricKind.synced);
    expect(choice.body, contains('Upside Down'));
  });

  test('medley y mix no llevan letra sincronizada', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Grupo - Fiesta Medley.mp3',
      durationSec: 300,
    );
    expect(id.medley, isTrue);
    final LyricChoice hit = chooseLrclibLyric(
      id,
      direct: _hit(
        artist: 'Grupo',
        title: 'Fiesta Medley',
        duration: 300,
        synced: _stamp(10, 'uno') + _stamp(290, 'dos'),
        plain: 'uno dos',
      ),
    );
    expect(hit.kind, LyricKind.plain);
    expect(hit.fileText, isNot(contains('[04:')));

    final LyricIdentity mix = lyricIdentity(
      path: 'Grupo - Enganchado Mix.mp3',
      durationSec: 400,
    );
    expect(mix.medley, isTrue);
    expect(lyricLooksMedley('Call Me (Remix)'), isFalse);
  });

  test('±10 s solo si el título es fuerte y la última línea cabe', () {
    final LyricIdentity id = lyricIdentity(
      path: 'a-ha - Take On Me.mp3',
      durationSec: 223,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 231,
          synced: _stamp(30, 'a') + _stamp(220, 'b'),
        ),
      ).kind,
      LyricKind.synced,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 231,
          synced: _stamp(30, 'a') + _stamp(230, 'b'),
        ),
      ).kind,
      LyricKind.none,
    );
  });

  test('503 no es sin letra, y el puntaje ordena con dudosas a la vista', () {
    expect(lyricHttpTransient(503), isTrue);
    expect(lyricHttpTransient(429), isTrue);
    expect(lyricHttpTransient(404), isFalse);
    expect(kLyricHttpTries, 3);
    expect(lyricRetryDelayMs(0), 1500);
    expect(lyricRetryDelayMs(1), 3000);
    expect(lyricFailureIsRetry(serverDown: true, hasText: false), isTrue);
    expect(lyricFailureIsRetry(serverDown: true, hasText: true), isFalse);
    final List<Uri> uris = lrclibManualUris(
      artist: 'Duncan Dhu',
      title: 'A Un Minuto',
      durationSec: 214,
      query: 'Duncan Dhu - A Un Minuto',
    );
    expect(uris[0].path, '/api/get');
    expect(uris[0].queryParameters.containsKey('album_name'), isFalse);
    expect(uris[2].queryParameters['q'], 'Duncan Dhu - A Un Minuto');

    final List<LyricCandidate> ranked = rankLyricCandidates(
      id: lyricIdentity(path: 'Duncan Dhu - A Un Minuto.mp3', durationSec: 214),
      rows: [
        _hit(
          artist: 'Otra',
          title: 'Tema lejano',
          duration: 90,
          synced: _stamp(1, 'no') + _stamp(80, 'no'),
        ),
        _hit(
          artist: 'MIKEL ERENTXUN (DUNCAN DHU)',
          title: 'A Un Minuto',
          duration: 214,
          synced: _stamp(12, 'si') + _stamp(200, 'si'),
        ),
      ],
    );
    expect(ranked.first.title, 'A Un Minuto');
    expect(ranked.first.doubtful, isFalse);
    expect(lyricDeltaBand(ranked.first.deltaSec), 'green');
    expect(ranked.last.doubtful, isTrue);
    expect(ranked.last.warning, isNotEmpty);
  });

  test('el Laboratorio reemplaza con bak y marca la dudosa', () async {
    expect(pathIsLab(r'C:\Music\GatoMix_LAB\a.mp3'), isTrue);
    expect(pathIsLab(r'C:\Music\Cumbias\a.mp3'), isFalse);

    const String buena =
        '[ar:Duncan Dhu]\n[ti:A Un Minuto]\n[00:12.00]si\n[03:20.00]si\n';
    final LyricFileVerdict ok = assessLabLyric(
      lrc: buena,
      artist: 'Duncan Dhu',
      title: 'A Un Minuto',
      durationSec: 214,
      siblingLrcs: const [],
    );
    expect(ok.fits, isTrue);
    expect(
      decideLabLyric(
        verdict: ok,
        serverDown: false,
        hasBetter: true,
      ),
      LabLyricAction.keep,
    );

    const String dup = '[00:12.00]misma\n[03:20.00]misma\n';
    final LyricFileVerdict copied = assessLabLyric(
      lrc: dup,
      artist: 'Duncan Dhu',
      title: 'A Un Minuto',
      durationSec: 214,
      siblingLrcs: const [dup],
    );
    expect(copied.gap, LyricGap.duplicate);
    expect(
      decideLabLyric(
        verdict: copied,
        serverDown: false,
        hasBetter: true,
      ),
      LabLyricAction.replace,
    );
    expect(
      decideLabLyric(
        verdict: copied,
        serverDown: true,
        hasBetter: false,
      ),
      LabLyricAction.retry,
    );
    expect(
      decideLabLyric(
        verdict: const LyricFileVerdict.bad(LyricGap.short),
        serverDown: false,
        hasBetter: false,
      ),
      LabLyricAction.doubt,
    );
    expect(lrcIsDoubtful(markLrcDoubtful(dup)), isTrue);
    expect(lrcIsNoRetry('$kLyricNoneMark\n'), isTrue);
    expect(lyricMayDownload(lrcExists: true), isFalse);

    final Directory dir = await Directory.systemTemp.createTemp('gmx_lrc');
    final File lrc = File('${dir.path}${Platform.pathSeparator}a.lrc');
    await lrc.writeAsString('vieja');
    await writeLrcKeepingBak(lrc.path, 'nueva');
    expect(File('${lrc.path}.bak').readAsStringSync(), 'vieja');
    expect(lrc.readAsStringSync(), 'nueva');
    expect(await restoreLrcBak(lrc.path), isTrue);
    expect(lrc.readAsStringSync(), 'vieja');
    await dir.delete(recursive: true);
  });

  test('Buscar letra penaliza karaoke y el resto de versiones', () {
    const String audio = 'Hello';
    expect(lyricEditionPenalty(audio, 'Hello'), 0);
    expect(lyricEditionPenalty('Hello (Karaoke)', 'Hello (Karaoke)'), 0);
    expect(lyricEditionPenalty('Hello (Live)', 'Hello (En Vivo)'), 0);
    expect(lyricEditionPenalty('Hello (Acústico)', 'Hello (Acoustic)'), 0);
    expect(lyricEditionPenalty('Hello (Live)', 'Hello (Karaoke)'), kLyricEditionPenalty);
    for (final String bad in <String>[
      'Hello - (Karaoke)',
      'Hello (Instrumental)',
      'Hello (Cover)',
      'Hello (Tribute)',
      'Hello (in the style of Lionel Richie)',
      'Hello (made famous by Lionel Richie)',
      'Hello (Remix)',
      'Hello (Live)',
      'Hello (Acústico)',
    ]) {
      expect(lyricEditionPenalty(audio, bad), kLyricEditionPenalty, reason: bad);
    }

    final List<LyricCandidate> ranked = rankLyricCandidates(
      id: const LyricIdentity(artist: 'Lionel Richie', title: 'Hello', durationSec: 242),
      voiceOnsetMs: 18000,
      rows: <Map<String, dynamic>>[
        _hit(
          artist: 'Lionel Richie',
          title: 'Hello - (Karaoke)',
          duration: 242,
          synced: _lrc(<(int, String)>[(18, 'karaoke'), (220, 'fin')]),
          id: 1,
        ),
        _hit(
          artist: 'Lionel Richie',
          title: 'Hello',
          duration: 242,
          synced: _lrc(<(int, String)>[(21, 'voz'), (220, 'fin')]),
          id: 2,
        ),
      ],
    );
    expect(ranked.first.title, 'Hello');
    expect(ranked[1].title, contains('Karaoke'));
    expect(ranked[1].doubtful, isTrue);
    expect(ranked.first.score, greaterThan(ranked[1].score));
  });

  test('el empate de Take On Me usa duración, la primera línea y /api/get', () {
    const LyricIdentity id = LyricIdentity(
      artist: 'a-ha',
      title: 'Take On Me',
      durationSec: 223,
    );
    final String alineada = _lrc(<(int, String)>[(12, 'voz'), (210, 'fin')]);
    final String desfasada = _lrc(<(int, String)>[(15, 'voz'), (213, 'fin')]);
    final List<LyricCandidate> porDuracion = rankLyricCandidates(
      id: id,
      rows: <Map<String, dynamic>>[
        _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 225,
          synced: desfasada,
          id: 10,
        ),
        _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 223,
          synced: alineada,
          id: 11,
        ),
      ],
    );
    expect(porDuracion.first.durationSec, 223);
    expect(porDuracion.first.deltaSec, lessThan(porDuracion[1].deltaSec));

    final List<LyricCandidate> porVoz = rankLyricCandidates(
      id: const LyricIdentity(artist: 'a-ha', title: 'Take On Me', durationSec: 225),
      voiceOnsetMs: 12000,
      rows: <Map<String, dynamic>>[
        _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 225,
          synced: _lrc(<(int, String)>[(15, 'tarde'), (210, 'fin')]),
          id: 12,
        ),
        _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 225,
          synced: _lrc(<(int, String)>[(12, 'voz'), (207, 'fin')]),
          id: 13,
          fromGet: true,
        ),
      ],
    );
    expect(porVoz.first.lrclibId, 13);
    expect((porVoz.first.firstStampMs! - 12000).abs(), lessThan(500));

    final List<LyricCandidate> porGet = rankLyricCandidates(
      id: const LyricIdentity(artist: 'a-ha', title: 'Take On Me', durationSec: 225),
      rows: <Map<String, dynamic>>[
        _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 225,
          synced: desfasada,
          id: 14,
        ),
        _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 225,
          synced: alineada,
          id: 15,
          fromGet: true,
        ),
      ],
    );
    expect(porGet.first.fromGet, isTrue);
    expect(porGet.first.lrclibId, 15);

    final int? onset = lyricVoiceOnsetMs(_sineAfterSilence(), 8000);
    expect(onset, isNotNull);
    expect((onset! - 1000).abs(), lessThan(80));
    expect(lyricVoiceOnsetMs(List<double>.filled(8000, 0), 8000), isNull);
    expect(lyricVoiceOnsetMs(_noise(8000), 8000), isNull);
  });

  test('entre varias de ±3 s manda la primera línea, no la duración exacta', () {
    const LyricIdentity hello = LyricIdentity(
      artist: 'Lionel Richie',
      title: 'Hello',
      durationSec: 242,
    );
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      _hit(
        artist: 'Lionel Richie',
        title: 'Hello',
        duration: 242,
        synced: _lrc(<(int, String)>[(15, 'get'), (230, 'fin')]),
        id: 20,
        fromGet: true,
      ),
      _hit(
        artist: 'Lionel Richie',
        title: 'Hello',
        duration: 240,
        synced: _lrc(<(int, String)>[(18, 'mejor'), (228, 'fin')]),
        id: 21,
      ),
    ];
    final List<LyricCandidate> sinMedir = rankLyricCandidates(id: hello, rows: rows);
    expect(sinMedir.first.fromGet, isTrue);
    expect(sinMedir.first.durationSec, 242);

    final List<LyricCandidate> medidas = rankLyricCandidates(
      id: hello,
      voiceOnsetMs: 18000,
      rows: rows,
    );
    expect(medidas.first.lrclibId, 21);
    expect(medidas.first.deltaSec, lessThanOrEqualTo(3));
    expect(
      (medidas.first.firstStampMs! - 18000).abs(),
      lessThan((medidas[1].firstStampMs! - 18000).abs()),
    );
  });

  test('Deshacer borra el .lrc si antes no había', () async {
    final Directory dir = await Directory.systemTemp.createTemp('gmx_lrc_nuevo');
    final File lrc = File('${dir.path}${Platform.pathSeparator}nuevo.lrc');
    await writeLrcKeepingBak(lrc.path, 'nueva');
    expect(File('${lrc.path}.bak').readAsStringSync().trim(), kLrcNoOriginalMark);
    expect(lrc.readAsStringSync(), 'nueva');
    expect(await undoAppliedLrc(lrc.path), isTrue);
    expect(lrc.existsSync(), isFalse);

    await lrc.writeAsString('vieja');
    await writeLrcKeepingBak(lrc.path, 'nueva');
    expect(await undoAppliedLrc(lrc.path), isTrue);
    expect(lrc.readAsStringSync(), 'vieja');
    await dir.delete(recursive: true);
  });
}

List<double> _sineAfterSilence() {
  const int sr = 8000;
  final List<double> x = List<double>.filled(sr * 2, 0);
  for (var i = sr; i < x.length; i++) {
    x[i] = 0.4 * math.sin(2 * math.pi * 200 * i / sr);
  }
  return x;
}

List<double> _noise(int n) {
  var state = 0x12345678;
  final List<double> x = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    state = (1664525 * state + 1013904223) & 0x7fffffff;
    x[i] = (state / 0x3fffffff) - 1;
  }
  return x;
}

Map<String, dynamic> _hit({
  required String artist,
  required String title,
  required int duration,
  String synced = '',
  String plain = '',
  String album = '',
  int? id,
  bool fromGet = false,
}) {
  return <String, dynamic>{
    'artistName': artist,
    'trackName': title,
    'albumName': album,
    'duration': duration,
    'syncedLyrics': synced,
    'plainLyrics': plain,
    'id': ?id,
    if (fromGet) kLyricFromGetKey: true,
  };
}

String _stamp(int sec, String text) {
  final String m = (sec ~/ 60).toString().padLeft(2, '0');
  final String s = (sec % 60).toString().padLeft(2, '0');
  return '[$m:$s.00]$text\n';
}

String _lrc(List<(int, String)> lines) =>
    lines.map(((int, String) e) => _stamp(e.$1, e.$2)).join();

List<int> _syncsafe(int n) => <int>[
  (n >> 21) & 0x7f,
  (n >> 14) & 0x7f,
  (n >> 7) & 0x7f,
  n & 0x7f,
];

List<int> _frame(String id, String text) {
  final List<int> payload = <int>[0x03, ...text.codeUnits];
  final int size = payload.length;
  return <int>[
    ...id.codeUnits,
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    0,
    0,
    ...payload,
  ];
}

List<int> _id3v23({
  required String title,
  required String artist,
  required String album,
}) {
  final List<int> frames = <int>[
    ..._frame('TIT2', title),
    ..._frame('TPE1', artist),
    ..._frame('TALB', album),
  ];
  return <int>[
    0x49,
    0x44,
    0x33,
    0x03,
    0x00,
    0x00,
    ..._syncsafe(frames.length),
    ...frames,
  ];
}
