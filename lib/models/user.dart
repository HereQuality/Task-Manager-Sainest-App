class AppUser {
  final String id;
  final String name;
  final String email;
  final String roleType; // "SuperAdmin" | "Employee"
  final String? roleSlug; // e.g. "manager" -- used for role-aware routing
  final String? roleName;
  final String? profilePic;

  AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.roleType,
    this.roleSlug,
    this.roleName,
    this.profilePic,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['_id'] ?? json['id'] ?? '',
      name: json['name'] ?? json['employeeName'] ?? json['fullName'] ?? json['username'] ?? 'User',
      email: json['email'] ?? json['emailOffice'] ?? '',
      roleType: json['roleType'] ?? 'Employee',
      roleSlug: json['roleSlug'],
      roleName: json['roleName'],
      profilePic: json['profilePic'],
    );
  }

  /// Mirrors the web client's getRoleSlug() fallback logic.
  String get effectiveSlug =>
      roleType == 'SuperAdmin' ? 'hqepl' : (roleSlug ?? 'employee');
}
