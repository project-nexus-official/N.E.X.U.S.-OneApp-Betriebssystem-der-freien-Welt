/// Central registry for all in-app help texts.
///
/// Key = contextId, value = [HelpEntry] with title + body.
/// All texts are in German, warm tone, max 3-4 sentences.
/// No technical jargon — designed for non-technical users.
library;

import 'package:flutter/foundation.dart';

class HelpEntry {
  final String title;
  final String body;
  const HelpEntry(this.title, this.body);
}

class HelpTexts {
  HelpTexts._();

  static const Map<String, HelpEntry> _entries = {

    // ── Zellen ──────────────────────────────────────────────────────────────

    'cell_general': HelpEntry(
      'Was ist eine Zelle?',
      'Eine Zelle ist deine Gemeinschaft innerhalb der Menschheitsfamilie — '
      'wie ein digitales Dorf. Du kannst einer lokalen Zelle in deiner '
      'Nachbarschaft beitreten oder einer thematischen Zelle mit '
      'Gleichgesinnten aus aller Welt. Zusammen trefft ihr Entscheidungen, '
      'teilt Neuigkeiten und unterstützt euch gegenseitig.',
    ),

    'cell_local': HelpEntry(
      'Lokale Zelle',
      'Eine lokale Zelle verbindet Menschen an einem bestimmten Ort — '
      'zum Beispiel in deiner Nachbarschaft, deinem Dorf oder deiner Stadt. '
      'N.E.X.U.S. nutzt GPS, um Zellen in deiner Nähe zu finden. '
      'So entsteht echte Gemeinschaft dort, wo du lebst.',
    ),

    'cell_thematic': HelpEntry(
      'Thematische Zelle',
      'Eine thematische Zelle verbindet Menschen über ein gemeinsames Thema — '
      'unabhängig davon, wo sie auf der Welt leben. '
      'Ob Nachhaltigkeit, Bildung, Musik oder Handwerk: '
      'Thematische Zellen bringen Gleichgesinnte zusammen.',
    ),

    'cell_bulletin': HelpEntry(
      'Pinnwand',
      'Die Pinnwand ist der offizielle Kanal der Zelle. '
      'Nur Gründer und Moderatoren können hier posten — '
      'für wichtige Ankündigungen, Termine und Neuigkeiten. '
      'Alle Mitglieder können lesen und mit Emojis reagieren.',
    ),

    'cell_discussion': HelpEntry(
      'Diskussion',
      'Die Diskussion ist der offene Austausch aller Zellenmitglieder. '
      'Hier kann jedes Mitglied schreiben — Fragen stellen, Ideen teilen, '
      'sich kennenlernen oder einfach plaudern. '
      'Wie ein Gemeinschaftsraum, der immer offen ist.',
    ),

    'cell_join_policy': HelpEntry(
      'Beitrittsregel',
      'Die Beitrittsregel legt fest, wie neue Mitglieder in die Zelle kommen. '
      '"Anfrage erforderlich" bedeutet: Interessierte schicken eine Anfrage, '
      'die Gründer oder Moderatoren bestätigen müssen. '
      '"Nur auf Einladung" bedeutet: Neue Mitglieder kommen ausschließlich '
      'durch eine persönliche Einladung eines bestehenden Mitglieds.',
    ),

    'cell_trust_level': HelpEntry(
      'Mindest-Vertrauensstufe',
      'Du kannst festlegen, wie gut neue Mitglieder dich (oder andere) '
      'bereits kennen müssen, um beizutreten. '
      '"Keine Einschränkung" steht die Zelle für alle offen. '
      '"Kontakt eines Mitglieds" bedeutet: Die Person muss jemanden '
      'in der Zelle als Kontakt haben. So wächst die Gemeinschaft '
      'durch echte Beziehungen.',
    ),

    // ── Agora & Governance ───────────────────────────────────────────────────

    'agora_general': HelpEntry(
      'Was ist die Agora?',
      'Die Agora ist der Ort der demokratischen Mitbestimmung — '
      'benannt nach dem Versammlungsplatz im alten Griechenland. '
      'Hier kann jedes Mitglied Anträge einbringen, diskutieren '
      'und abstimmen. Gemeinsam entscheidet die Gemeinschaft, '
      'nicht eine einzelne Person.',
    ),

    'proposal_general': HelpEntry(
      'Was ist ein Antrag?',
      'Ein Antrag ist ein Vorschlag, über den die Zelle gemeinsam entscheidet. '
      'Jedes Mitglied kann einen Antrag einbringen — '
      'zum Beispiel für eine neue Regel, ein gemeinsames Projekt '
      'oder eine wichtige Entscheidung. '
      'Erst wird diskutiert, dann abgestimmt.',
    ),

    'proposal_status': HelpEntry(
      'Was bedeuten die Status?',
      'Ein Antrag durchläuft mehrere Phasen: '
      '"Entwurf" ist noch nicht veröffentlicht. '
      '"Diskussion" — alle können Meinungen einbringen. '
      '"Abstimmung" — jetzt zählen die Stimmen. '
      '"Entschieden" — das Ergebnis steht fest. '
      '"Archiviert" — der Antrag ist abgeschlossen.',
    ),

    'voting_general': HelpEntry(
      'Wie funktioniert die Abstimmung?',
      'Bei einer Abstimmung hast du drei Möglichkeiten: '
      'Ja, Nein oder Enthaltung. '
      'Deine Stimme ist anonym und zählt gleichwertig. '
      'Das Ergebnis richtet sich nach dem vorher festgelegten Quorum — '
      'dem Mindestanteil an Stimmen, der erreicht werden muss.',
    ),

    'quadratic_voting': HelpEntry(
      'Quadratisches Wählen',
      'Beim Quadratischen Wählen kannst du für besonders wichtige Themen '
      'mehr Stimmpunkte einsetzen. Aber: Die Kosten steigen quadratisch — '
      '2 Stimmen kosten 4 Punkte, 3 Stimmen kosten 9 Punkte. '
      'So kann niemand einfach alle Themen dominieren, '
      'und wirklich wichtige Anliegen bekommen mehr Gewicht.',
    ),

    'delegation_general': HelpEntry(
      'Was ist Delegation?',
      'Du kannst deine Stimme bei einem bestimmten Thema jemandem '
      'anvertrauen, dem du dort vertraust — zum Beispiel einer '
      'Fachperson oder einem Freund. '
      'Deine Stimme wandert dann automatisch zu dieser Person. '
      'Du kannst die Delegation jederzeit widerrufen.',
    ),

    'grundstimmrecht': HelpEntry(
      'Grundstimm-Recht',
      'Bei fundamentalen Fragen — zum Beispiel Änderungen der '
      'Gemeinschaftsregeln — gilt das Grundstimm-Recht: '
      '1 Mensch, 1 Stimme. Keine Delegation, keine Gewichtung. '
      'Jede Stimme zählt gleich, egal wer die Person ist. '
      'Das schützt die Grundrechte aller Mitglieder.',
    ),

    // ── Dorfplatz ────────────────────────────────────────────────────────────

    'dorfplatz_general': HelpEntry(
      'Was ist der Dorfplatz?',
      'Der Dorfplatz ist der dezentrale Treffpunkt der Menschheitsfamilie — '
      'wie ein Marktplatz ohne Algorithmus, ohne Werbung. '
      'Beiträge erscheinen in chronologischer Reihenfolge. '
      'Du entscheidest, was du siehst — nicht ein Unternehmen.',
    ),

    'dorfplatz_visibility': HelpEntry(
      'Wer sieht deinen Beitrag?',
      '"Kontakte" — nur Menschen, die du als Kontakt hast, sehen den Beitrag. '
      '"Meine Zelle" — alle Mitglieder deiner Zelle sehen ihn. '
      '"Öffentlich" — alle in der Menschheitsfamilie können ihn sehen. '
      'Du kannst die Sichtbarkeit jederzeit vor dem Posten ändern.',
    ),

    // ── Kontakte & Vertrauen ─────────────────────────────────────────────────

    'trust_levels': HelpEntry(
      'Vertrauensstufen',
      'In N.E.X.U.S. gibt es vier Stufen: '
      '"Entdeckt" — du hast die Person gesehen, aber nicht bestätigt. '
      '"Kontakt" — du kennst die Person. '
      '"Vertrauensperson" — du vertraust ihr besonders. '
      '"Bürge" — du bürgst für ihre Identität. '
      'Je höher die Stufe, desto mehr Informationen teilst du.',
    ),

    'selective_disclosure': HelpEntry(
      'Selective Disclosure',
      'Du entscheidest für jedes Profilfeld einzeln, wer es sehen darf. '
      'Zum Beispiel: Dein Name ist für alle sichtbar, '
      'aber dein Geburtsdatum nur für Vertrauenspersonen. '
      'Deine Daten gehören dir — du hast die volle Kontrolle.',
    ),

    'contact_request': HelpEntry(
      'Kontaktanfragen',
      'Bevor jemand mit dir chatten kann, muss er eine Kontaktanfrage senden. '
      'Das schützt dich vor ungewollten Nachrichten. '
      'Du kannst Anfragen annehmen, ablehnen oder einfach ignorieren — '
      'der Absender erfährt dabei nichts über deine Entscheidung.',
    ),

    // ── Identität ────────────────────────────────────────────────────────────

    'seed_phrase': HelpEntry(
      'Was ist die Seed Phrase?',
      'Die Seed Phrase sind 12 Wörter, die deine digitale Identität sichern. '
      'Sie ist wie ein Schlüssel zu deinem Konto — wer diese Wörter kennt, '
      'kann auf dein Konto zugreifen. '
      'Schreibe sie auf Papier und bewahre sie an einem sicheren Ort auf. '
      'Teile sie niemals mit jemandem.',
    ),

    'did_key': HelpEntry(
      'Was ist eine DID?',
      'DID steht für "Dezentralisierte Identität" — dein digitaler Ausweis, '
      'der dir allein gehört. Kein Unternehmen und kein Staat kontrolliert ihn. '
      'Deine DID wird aus deiner Seed Phrase berechnet und ist einzigartig. '
      'Andere können damit sicherstellen, dass eine Nachricht wirklich von dir stammt.',
    ),

    // ── Einladungen ──────────────────────────────────────────────────────────

    'invite_code': HelpEntry(
      'Einladungscode',
      'Mit einem Einladungscode kannst du Freunde in die Menschheitsfamilie einladen. '
      'Wer deinen Code einlöst, wird automatisch dein Kontakt — '
      'ganz ohne Kontaktanfrage. '
      'Jeder Code ist 30 Tage gültig und kann nur einmal verwendet werden.',
    ),

    // ── Kanäle ───────────────────────────────────────────────────────────────

    'channel_types': HelpEntry(
      'Kanal-Modi',
      'Im "Diskussions"-Modus können alle Mitglieder Nachrichten senden — '
      'ideal für offenen Austausch. '
      'Im "Ankündigungs"-Modus können nur Admins posten, '
      'alle anderen lesen nur mit. '
      'Wähle den Modus passend zum Zweck deines Kanals.',
    ),

    'channel_privacy': HelpEntry(
      'Kanal-Sichtbarkeit',
      '"Öffentlich" — der Kanal ist für alle sichtbar und beitrittsfähig. '
      '"Privat sichtbar" — der Kanal ist auffindbar, aber Beitritt '
      'nur auf Anfrage. '
      '"Privat versteckt" — der Kanal ist unsichtbar, '
      'Beitritt nur per persönlicher Einladung.',
    ),
  };

  /// Returns the [HelpEntry] for [contextId], or a fallback if unknown.
  static HelpEntry get(String contextId) {
    final entry = _entries[contextId];
    if (entry == null) {
      debugPrint('[HELP] Warning: Unknown contextId: $contextId');
      return const HelpEntry(
        'Hilfe',
        'Zu diesem Bereich gibt es noch keinen Hilfetext.',
      );
    }
    debugPrint('[HELP] Showing help for: $contextId');
    return entry;
  }

  /// Returns true if [contextId] is defined.
  static bool has(String contextId) => _entries.containsKey(contextId);
}

