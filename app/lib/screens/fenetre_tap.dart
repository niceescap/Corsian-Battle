/// Fenêtre de tap d'un doublon, côté client.
///
/// Trois notions coexistent volontairement :
///
/// - `rouge` : le tapis est teinté (état **visuel**) ;
/// - `montee` : la zone tactile est présente ;
/// - `autorisee` : un appui est recevable par le serveur (état **logique**).
///
/// Le rouge peut disparaître avant le verdict (`doublon_resolu` peut arriver
/// après le `pli_gagne` qui déclenche le ramassage). Autoriser le tap sur la
/// seule couleur du tapis faisait perdre l'appui : l'invité tapait dans le
/// vide pendant que le créateur finissait par trancher. L'autorisation suit
/// donc [ouvrir] et ne retombe qu'avec [resoudre].
class FenetreTap {
  bool _visible = false;
  bool _autorisee = false;
  bool _envoye = false;
  DateTime? debut;

  /// Vrai si la zone rouge doit être affichée.
  bool get rouge => _visible;

  /// Vrai si un appui a déjà été consommé pour cette fenêtre.
  bool get envoye => _envoye;

  /// Vrai si la zone tactile doit être montée.
  ///
  /// Elle reste montée tant que la fenêtre n'est pas résolue, même si le
  /// rouge a été fermé visuellement : un appui doit rester recevable.
  bool get montee => _autorisee && debut != null;

  /// Vrai si un appui est recevable (fenêtre ouverte, début connu, non déjà
  /// envoyé).
  bool get autorisee => _autorisee && debut != null && !_envoye;

  /// Ouvre une fenêtre à l'instant de réception de `doublon_ouvert`.
  ///
  /// Remet aussi le compteur d'envoi : le serveur ne retient qu'un `tape` par
  /// siège et par fenêtre.
  void ouvrir(DateTime instant) {
    _visible = true;
    _autorisee = true;
    _envoye = false;
    debut = instant;
  }

  /// Referme tout après un verdict (`doublon_resolu`, `pli_gagne`, fin de
  /// partie) : plus aucun appui recevable.
  void resoudre() {
    _visible = false;
    _autorisee = false;
    _envoye = false;
    debut = null;
  }

  /// Ferme la zone visuelle sans toucher à l'autorisation (ramassage
  /// anticipé, avant `doublon_resolu`).
  void fermerVisuel() {
    _visible = false;
  }

  /// Consomme un appui : renvoie le délai mesuré, ou `null` si l'appui doit
  /// être ignoré (pas de début de fenêtre, fenêtre close, ou déjà envoyé).
  int? enregistrerTap(DateTime instant) {
    final debutFenetre = debut;
    if (debutFenetre == null || !_autorisee || _envoye) return null;
    _envoye = true;
    return instant.difference(debutFenetre).inMilliseconds;
  }
}
