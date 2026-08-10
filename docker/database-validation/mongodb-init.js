const validation = db.getSiblingDB('lithe_test');

validation.items.deleteMany({});
validation.items.insertMany([
  {
    _id: ObjectId('66b5a9a00000000000000001'),
    name: '中文 / emoji 🚀',
    empty_value: '',
    nullable_value: null,
    active: true,
    score: NumberInt(42),
    amount: NumberDecimal('1234.50'),
    happened_at: ISODate('2026-08-10T09:30:00.123Z'),
    nested: { region: 'cn', labels: ['demo', '数据库'] },
    binary_value: new BinData(0, 'AAEC')
  },
  {
    _id: ObjectId('66b5a9a00000000000000002'),
    name: 'second row',
    empty_value: 'filled',
    nullable_value: null,
    active: false,
    score: NumberInt(7),
    amount: NumberDecimal('0.01'),
    happened_at: ISODate('2026-08-11T10:45:01.000Z'),
    nested: { region: 'us', labels: [] },
    binary_value: new BinData(0, '/wA=')
  }
]);

validation.items.createIndex({ name: 1 }, { name: 'items_name_idx' });
validation.items.createIndex({ active: 1, score: -1 }, { name: 'items_active_score_idx' });
