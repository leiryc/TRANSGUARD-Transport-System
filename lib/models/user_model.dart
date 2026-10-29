import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String userType; // 'passenger' or 'driver'
  final String? profileImage;
  final double rating;
  final int totalRides;
  final DateTime createdAt;
  final bool isActive;
  final bool isApproved;
  final String? approvalStatus;
  final String? franchiseNumber;
  final String? plateNumber;
  final bool isFromCache;

  UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    required this.userType,
    this.profileImage,
    this.rating = 5.0,
    this.totalRides = 0,
    required this.createdAt,
    this.isActive = true,
    this.isApproved = false,
    this.approvalStatus,
    this.franchiseNumber,
    this.plateNumber,
    this.isFromCache = false,
  });

  factory UserModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final userType = data['userType'] ?? 'passenger';
    return UserModel(
      id: doc.id,
      name: data['name'] ?? '',
      email: data['email'] ?? '',
      phone: data['phone'] ?? '',
      userType: userType,
      profileImage: data['profileImage'],
      rating: (data['rating'] ?? 5.0).toDouble(),
      totalRides: data['totalRides'] ?? 0,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      isActive: data['isActive'] ?? true,
      isApproved: data['isApproved'] ?? userType != 'driver',
      approvalStatus: data['approvalStatus'],
      franchiseNumber: data['franchiseNumber'],
      plateNumber: data['plateNumber'],
      isFromCache: doc.metadata.isFromCache,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'email': email,
      'phone': phone,
      'userType': userType,
      'profileImage': profileImage,
      'rating': rating,
      'totalRides': totalRides,
      'createdAt': Timestamp.fromDate(createdAt),
      'isActive': isActive,
      'isApproved': userType != 'driver',
      if (userType == 'driver') ...{
        'approvalStatus': 'pending',
        'franchiseNumber': franchiseNumber,
        'plateNumber': plateNumber,
      },
    };
  }
}
