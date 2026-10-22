/// Erreur réseau « lisible » : un code technique et un message affichable.
///
/// Le serveur s'interdit d'envoyer une trace de pile (`docs/ENDPOINTS.md` §2) :
/// ses messages sont déjà affichables tels quels. On les remonte donc tels
/// quels, et on n'ajoute que le code pour permettre une décision technique
/// (renouveler le jeton, retenter, abandonner).
class ErreurReseau implements Exception {
  /// Code technique renvoyé par le serveur (`pseudo_indisponible`, …),
  /// ou un code local (`reseau_injoignable`, `http_500`).
  final String code;

  /// Message affichable tel quel.
  final String message;

  /// Statut HTTP, si la réponse en a un. `0` pour une erreur de transport.
  final int statut;

  const ErreurReseau(this.code, this.message, {this.statut = 0});

  /// Le serveur a-t-il refusé le jeton ? Dans ce cas, il faut le renouveler.
  bool get jetonInvalide =>
      code == 'non_autorise' ||
      code == 'jeton_invalide' ||
      code == 'jeton_expire' ||
      statut == 401;

  /// Limite de débit atteinte : l'app doit attendre avant de réessayer.
  bool get debitAtteint => statut == 429 || code == 'trop_de_comptes';

  @override
  String toString() => 'ErreurReseau($code, $message, statut=$statut)';
}
