// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'track_metadata.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetTrackMetadataCollection on Isar {
  IsarCollection<TrackMetadata> get trackMetadatas => this.collection();
}

const TrackMetadataSchema = CollectionSchema(
  name: r'TrackMetadata',
  id: -8734757490720156662,
  properties: {
    r'cueInMs': PropertySchema(id: 0, name: r'cueInMs', type: IsarType.long),
    r'filePath': PropertySchema(
      id: 1,
      name: r'filePath',
      type: IsarType.string,
    ),
    r'genreAssigned': PropertySchema(
      id: 2,
      name: r'genreAssigned',
      type: IsarType.string,
    ),
    r'hasBpm': PropertySchema(id: 3, name: r'hasBpm', type: IsarType.bool),
    r'hasCurve': PropertySchema(id: 4, name: r'hasCurve', type: IsarType.bool),
    r'hasLyrics': PropertySchema(
      id: 5,
      name: r'hasLyrics',
      type: IsarType.bool,
    ),
    r'mixDurationMs': PropertySchema(
      id: 6,
      name: r'mixDurationMs',
      type: IsarType.long,
    ),
    r'mixOutMs': PropertySchema(id: 7, name: r'mixOutMs', type: IsarType.long),
    r'mixProfile': PropertySchema(
      id: 8,
      name: r'mixProfile',
      type: IsarType.string,
    ),
  },
  estimateSize: _trackMetadataEstimateSize,
  serialize: _trackMetadataSerialize,
  deserialize: _trackMetadataDeserialize,
  deserializeProp: _trackMetadataDeserializeProp,
  idName: r'id',
  indexes: {
    r'filePath': IndexSchema(
      id: 2918041768256347220,
      name: r'filePath',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'filePath',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},
  getId: _trackMetadataGetId,
  getLinks: _trackMetadataGetLinks,
  attach: _trackMetadataAttach,
  version: '3.1.0+1',
);

int _trackMetadataEstimateSize(
  TrackMetadata object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.filePath.length * 3;
  bytesCount += 3 + object.genreAssigned.length * 3;
  bytesCount += 3 + object.mixProfile.length * 3;
  return bytesCount;
}

void _trackMetadataSerialize(
  TrackMetadata object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.cueInMs);
  writer.writeString(offsets[1], object.filePath);
  writer.writeString(offsets[2], object.genreAssigned);
  writer.writeBool(offsets[3], object.hasBpm);
  writer.writeBool(offsets[4], object.hasCurve);
  writer.writeBool(offsets[5], object.hasLyrics);
  writer.writeLong(offsets[6], object.mixDurationMs);
  writer.writeLong(offsets[7], object.mixOutMs);
  writer.writeString(offsets[8], object.mixProfile);
}

TrackMetadata _trackMetadataDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = TrackMetadata();
  object.cueInMs = reader.readLongOrNull(offsets[0]);
  object.filePath = reader.readString(offsets[1]);
  object.genreAssigned = reader.readString(offsets[2]);
  object.hasBpm = reader.readBool(offsets[3]);
  object.hasCurve = reader.readBool(offsets[4]);
  object.hasLyrics = reader.readBool(offsets[5]);
  object.id = id;
  object.mixDurationMs = reader.readLong(offsets[6]);
  object.mixOutMs = reader.readLongOrNull(offsets[7]);
  object.mixProfile = reader.readString(offsets[8]);
  return object;
}

P _trackMetadataDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLongOrNull(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readBool(offset)) as P;
    case 4:
      return (reader.readBool(offset)) as P;
    case 5:
      return (reader.readBool(offset)) as P;
    case 6:
      return (reader.readLong(offset)) as P;
    case 7:
      return (reader.readLongOrNull(offset)) as P;
    case 8:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _trackMetadataGetId(TrackMetadata object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _trackMetadataGetLinks(TrackMetadata object) {
  return [];
}

void _trackMetadataAttach(
  IsarCollection<dynamic> col,
  Id id,
  TrackMetadata object,
) {
  object.id = id;
}

extension TrackMetadataByIndex on IsarCollection<TrackMetadata> {
  Future<TrackMetadata?> getByFilePath(String filePath) {
    return getByIndex(r'filePath', [filePath]);
  }

  TrackMetadata? getByFilePathSync(String filePath) {
    return getByIndexSync(r'filePath', [filePath]);
  }

  Future<bool> deleteByFilePath(String filePath) {
    return deleteByIndex(r'filePath', [filePath]);
  }

  bool deleteByFilePathSync(String filePath) {
    return deleteByIndexSync(r'filePath', [filePath]);
  }

  Future<List<TrackMetadata?>> getAllByFilePath(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return getAllByIndex(r'filePath', values);
  }

  List<TrackMetadata?> getAllByFilePathSync(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'filePath', values);
  }

  Future<int> deleteAllByFilePath(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'filePath', values);
  }

  int deleteAllByFilePathSync(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'filePath', values);
  }

  Future<Id> putByFilePath(TrackMetadata object) {
    return putByIndex(r'filePath', object);
  }

  Id putByFilePathSync(TrackMetadata object, {bool saveLinks = true}) {
    return putByIndexSync(r'filePath', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByFilePath(List<TrackMetadata> objects) {
    return putAllByIndex(r'filePath', objects);
  }

  List<Id> putAllByFilePathSync(
    List<TrackMetadata> objects, {
    bool saveLinks = true,
  }) {
    return putAllByIndexSync(r'filePath', objects, saveLinks: saveLinks);
  }
}

extension TrackMetadataQueryWhereSort
    on QueryBuilder<TrackMetadata, TrackMetadata, QWhere> {
  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension TrackMetadataQueryWhere
    on QueryBuilder<TrackMetadata, TrackMetadata, QWhereClause> {
  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhereClause> idEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhereClause> idNotEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhereClause> idGreaterThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhereClause> idLessThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerId,
          includeLower: includeLower,
          upper: upperId,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhereClause> filePathEqualTo(
    String filePath,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'filePath', value: [filePath]),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterWhereClause>
  filePathNotEqualTo(String filePath) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [],
                upper: [filePath],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [filePath],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [filePath],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [],
                upper: [filePath],
                includeUpper: false,
              ),
            );
      }
    });
  }
}

extension TrackMetadataQueryFilter
    on QueryBuilder<TrackMetadata, TrackMetadata, QFilterCondition> {
  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  cueInMsIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'cueInMs'),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  cueInMsIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'cueInMs'),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  cueInMsEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'cueInMs', value: value),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  cueInMsGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'cueInMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  cueInMsLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'cueInMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  cueInMsBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'cueInMs',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'filePath',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'filePath',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'filePath', value: ''),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  filePathIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'filePath', value: ''),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'genreAssigned',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'genreAssigned',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'genreAssigned',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'genreAssigned',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'genreAssigned',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'genreAssigned',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'genreAssigned',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'genreAssigned',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'genreAssigned', value: ''),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  genreAssignedIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'genreAssigned', value: ''),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  hasBpmEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'hasBpm', value: value),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  hasCurveEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'hasCurve', value: value),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  hasLyricsEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'hasLyrics', value: value),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition> idEqualTo(
    Id value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  idGreaterThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'id',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixDurationMsEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'mixDurationMs', value: value),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixDurationMsGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'mixDurationMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixDurationMsLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'mixDurationMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixDurationMsBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'mixDurationMs',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixOutMsIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'mixOutMs'),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixOutMsIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'mixOutMs'),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixOutMsEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'mixOutMs', value: value),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixOutMsGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'mixOutMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixOutMsLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'mixOutMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixOutMsBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'mixOutMs',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'mixProfile',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'mixProfile',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'mixProfile',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'mixProfile',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'mixProfile',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'mixProfile',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'mixProfile',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'mixProfile',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'mixProfile', value: ''),
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterFilterCondition>
  mixProfileIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'mixProfile', value: ''),
      );
    });
  }
}

extension TrackMetadataQueryObject
    on QueryBuilder<TrackMetadata, TrackMetadata, QFilterCondition> {}

extension TrackMetadataQueryLinks
    on QueryBuilder<TrackMetadata, TrackMetadata, QFilterCondition> {}

extension TrackMetadataQuerySortBy
    on QueryBuilder<TrackMetadata, TrackMetadata, QSortBy> {
  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByCueInMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cueInMs', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByCueInMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cueInMs', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByFilePath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByFilePathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByGenreAssigned() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genreAssigned', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByGenreAssignedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genreAssigned', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByHasBpm() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasBpm', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByHasBpmDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasBpm', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByHasCurve() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasCurve', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByHasCurveDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasCurve', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByHasLyrics() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasLyrics', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByHasLyricsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasLyrics', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByMixDurationMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixDurationMs', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByMixDurationMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixDurationMs', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByMixOutMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixOutMs', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByMixOutMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixOutMs', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> sortByMixProfile() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixProfile', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  sortByMixProfileDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixProfile', Sort.desc);
    });
  }
}

extension TrackMetadataQuerySortThenBy
    on QueryBuilder<TrackMetadata, TrackMetadata, QSortThenBy> {
  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByCueInMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cueInMs', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByCueInMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cueInMs', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByFilePath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByFilePathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByGenreAssigned() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genreAssigned', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByGenreAssignedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genreAssigned', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByHasBpm() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasBpm', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByHasBpmDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasBpm', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByHasCurve() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasCurve', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByHasCurveDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasCurve', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByHasLyrics() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasLyrics', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByHasLyricsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasLyrics', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByMixDurationMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixDurationMs', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByMixDurationMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixDurationMs', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByMixOutMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixOutMs', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByMixOutMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixOutMs', Sort.desc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy> thenByMixProfile() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixProfile', Sort.asc);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QAfterSortBy>
  thenByMixProfileDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mixProfile', Sort.desc);
    });
  }
}

extension TrackMetadataQueryWhereDistinct
    on QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> {
  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> distinctByCueInMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'cueInMs');
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> distinctByFilePath({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'filePath', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct>
  distinctByGenreAssigned({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(
        r'genreAssigned',
        caseSensitive: caseSensitive,
      );
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> distinctByHasBpm() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hasBpm');
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> distinctByHasCurve() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hasCurve');
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> distinctByHasLyrics() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hasLyrics');
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct>
  distinctByMixDurationMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'mixDurationMs');
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> distinctByMixOutMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'mixOutMs');
    });
  }

  QueryBuilder<TrackMetadata, TrackMetadata, QDistinct> distinctByMixProfile({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'mixProfile', caseSensitive: caseSensitive);
    });
  }
}

extension TrackMetadataQueryProperty
    on QueryBuilder<TrackMetadata, TrackMetadata, QQueryProperty> {
  QueryBuilder<TrackMetadata, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<TrackMetadata, int?, QQueryOperations> cueInMsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'cueInMs');
    });
  }

  QueryBuilder<TrackMetadata, String, QQueryOperations> filePathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'filePath');
    });
  }

  QueryBuilder<TrackMetadata, String, QQueryOperations>
  genreAssignedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'genreAssigned');
    });
  }

  QueryBuilder<TrackMetadata, bool, QQueryOperations> hasBpmProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hasBpm');
    });
  }

  QueryBuilder<TrackMetadata, bool, QQueryOperations> hasCurveProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hasCurve');
    });
  }

  QueryBuilder<TrackMetadata, bool, QQueryOperations> hasLyricsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hasLyrics');
    });
  }

  QueryBuilder<TrackMetadata, int, QQueryOperations> mixDurationMsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'mixDurationMs');
    });
  }

  QueryBuilder<TrackMetadata, int?, QQueryOperations> mixOutMsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'mixOutMs');
    });
  }

  QueryBuilder<TrackMetadata, String, QQueryOperations> mixProfileProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'mixProfile');
    });
  }
}
