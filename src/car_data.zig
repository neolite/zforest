//! zcar catalog: brands → models → year ranges → powertrain specs,
//! plus the service menu grouped by repair category. Pure comptime
//! data + tiny lookups — no allocations, fully testable.

const std = @import("std");

pub const Spec = struct {
    engine: []const u8,
    gearbox: []const u8,
    drivetrain: []const u8,
};

pub const Model = struct {
    name: []const u8,
    year_lo: u16,
    year_hi: u16,
    spec: Spec,
};

pub const Brand = struct {
    name: []const u8,
    models: []const Model,
};

pub const brands = [_]Brand{
    .{ .name = "Toyota", .models = &.{
        .{ .name = "Camry", .year_lo = 2011, .year_hi = 2024, .spec = .{ .engine = "2.5 MPI 181 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "передний" } },
        .{ .name = "Corolla", .year_lo = 2008, .year_hi = 2024, .spec = .{ .engine = "1.6 MPI 122 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "передний" } },
        .{ .name = "RAV4", .year_lo = 2013, .year_hi = 2024, .spec = .{ .engine = "2.0 MPI 149 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "полный" } },
        .{ .name = "Land Cruiser", .year_lo = 2008, .year_hi = 2024, .spec = .{ .engine = "4.0 дизель 249 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "полный" } },
    } },
    .{ .name = "Volkswagen", .models = &.{
        .{ .name = "Polo", .year_lo = 2015, .year_hi = 2024, .spec = .{ .engine = "1.6 MPI 110 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "передний" } },
        .{ .name = "Tiguan", .year_lo = 2016, .year_hi = 2024, .spec = .{ .engine = "2.0 TSI 180 л.с.", .gearbox = "АКПП 7-ст.", .drivetrain = "полный" } },
        .{ .name = "Passat", .year_lo = 2011, .year_hi = 2024, .spec = .{ .engine = "1.8 TSI 180 л.с.", .gearbox = "робот 7-ст.", .drivetrain = "передний" } },
        .{ .name = "Golf", .year_lo = 2009, .year_hi = 2024, .spec = .{ .engine = "1.4 TSI 122 л.с.", .gearbox = "робот 7-ст.", .drivetrain = "передний" } },
    } },
    .{ .name = "Kia", .models = &.{
        .{ .name = "Rio", .year_lo = 2011, .year_hi = 2024, .spec = .{ .engine = "1.6 MPI 123 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "передний" } },
        .{ .name = "Sportage", .year_lo = 2016, .year_hi = 2024, .spec = .{ .engine = "2.0 TCI 150 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "полный" } },
        .{ .name = "Cerato", .year_lo = 2013, .year_hi = 2024, .spec = .{ .engine = "1.6 MPI 130 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "передний" } },
    } },
    .{ .name = "Hyundai", .models = &.{
        .{ .name = "Solaris", .year_lo = 2010, .year_hi = 2024, .spec = .{ .engine = "1.6 MPI 123 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "передний" } },
        .{ .name = "Creta", .year_lo = 2016, .year_hi = 2024, .spec = .{ .engine = "2.0 MPI 150 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "передний" } },
        .{ .name = "Tucson", .year_lo = 2015, .year_hi = 2024, .spec = .{ .engine = "2.0 CRDi 150 л.с.", .gearbox = "АКПП 6-ст.", .drivetrain = "полный" } },
    } },
    .{ .name = "Lada", .models = &.{
        .{ .name = "Vesta", .year_lo = 2015, .year_hi = 2024, .spec = .{ .engine = "1.6 MPI 122 л.с.", .gearbox = "МКПП 5-ст.", .drivetrain = "передний" } },
        .{ .name = "Granta", .year_lo = 2011, .year_hi = 2024, .spec = .{ .engine = "1.6 MPI 98 л.с.", .gearbox = "МКПП 5-ст.", .drivetrain = "передний" } },
        .{ .name = "Niva Travel", .year_lo = 2020, .year_hi = 2024, .spec = .{ .engine = "1.7 MPI 83 л.с.", .gearbox = "МКПП 5-ст.", .drivetrain = "полный" } },
    } },
    .{ .name = "BMW", .models = &.{
        .{ .name = "3 Series", .year_lo = 2012, .year_hi = 2024, .spec = .{ .engine = "2.0i 184 л.с.", .gearbox = "АКПП 8-ст.", .drivetrain = "задний" } },
        .{ .name = "X3", .year_lo = 2010, .year_hi = 2024, .spec = .{ .engine = "2.0d 190 л.с.", .gearbox = "АКПП 8-ст.", .drivetrain = "полный" } },
        .{ .name = "X5", .year_lo = 2013, .year_hi = 2024, .spec = .{ .engine = "3.0d 249 л.с.", .gearbox = "АКПП 8-ст.", .drivetrain = "полный" } },
    } },
};

pub fn brandAt(i: usize) ?*const Brand {
    return if (i < brands.len) &brands[i] else null;
}

pub fn modelAt(b: usize, m: usize) ?*const Model {
    const br = brandAt(b) orelse return null;
    return if (m < br.models.len) &br.models[m] else null;
}

pub const Cat = enum {
    maintenance,
    engine,
    gearbox,
    suspension,
    tires,
    body,
    electric,

    pub fn name(c: Cat) []const u8 {
        return switch (c) {
            .maintenance => "ТО и расходники",
            .engine => "Двигатель",
            .gearbox => "Коробка передач",
            .suspension => "Ходовая",
            .tires => "Шиномонтаж",
            .body => "Кузов",
            .electric => "Электрика",
        };
    }
};

pub const cat_order = [_]Cat{ .maintenance, .engine, .gearbox, .suspension, .tires, .body, .electric };

pub const Service = struct {
    id: u32,
    cat: Cat,
    name: []const u8,
    /// price in rubles
    price: u32,
    /// duration in minutes, 0 = not applicable
    dur: u16,
};

pub const services = [_]Service{
    .{ .id = 1, .cat = .maintenance, .name = "ТО-1: масло + фильтры", .price = 4500, .dur = 60 },
    .{ .id = 2, .cat = .maintenance, .name = "ТО-2: масло + фильтры + свечи", .price = 6800, .dur = 90 },
    .{ .id = 3, .cat = .maintenance, .name = "ТО-3: полное (масла, фильтры, жидкости)", .price = 9200, .dur = 120 },
    .{ .id = 4, .cat = .maintenance, .name = "Замена салонного фильтра", .price = 1400, .dur = 20 },
    .{ .id = 5, .cat = .maintenance, .name = "Замена воздушного фильтра", .price = 1000, .dur = 20 },
    .{ .id = 6, .cat = .engine, .name = "Замена цепи ГРМ (компл)", .price = 18500, .dur = 480 },
    .{ .id = 7, .cat = .engine, .name = "Замена свечей зажигания", .price = 3200, .dur = 40 },
    .{ .id = 8, .cat = .engine, .name = "Ремонт форсунок (компл)", .price = 9800, .dur = 240 },
    .{ .id = 9, .cat = .engine, .name = "Замена масла ДВС + пробег", .price = 1600, .dur = 30 },
    .{ .id = 10, .cat = .gearbox, .name = "Замена масла АКПП", .price = 4800, .dur = 60 },
    .{ .id = 11, .cat = .gearbox, .name = "Диагностика коробки передач", .price = 2200, .dur = 60 },
    .{ .id = 12, .cat = .gearbox, .name = "Ремонт стартера", .price = 7200, .dur = 180 },
    .{ .id = 13, .cat = .suspension, .name = "Замена амортизаторов (компл 2)", .price = 15800, .dur = 240 },
    .{ .id = 14, .cat = .suspension, .name = "Развал-схождение", .price = 2600, .dur = 60 },
    .{ .id = 15, .cat = .suspension, .name = "Замена сайлентблоков", .price = 5800, .dur = 300 },
    .{ .id = 16, .cat = .tires, .name = "Шиномонтаж (компл 4 колеса)", .price = 2500, .dur = 90 },
    .{ .id = 17, .cat = .tires, .name = "Балансировка (компл)", .price = 1400, .dur = 40 },
    .{ .id = 18, .cat = .tires, .name = "Хранение шин (сезон)", .price = 3600, .dur = 0 },
    .{ .id = 19, .cat = .body, .name = "Полировка кузова", .price = 12500, .dur = 480 },
    .{ .id = 20, .cat = .body, .name = "Антикор обработка", .price = 18900, .dur = 600 },
    .{ .id = 21, .cat = .electric, .name = "Диагностика электрики", .price = 2600, .dur = 90 },
    .{ .id = 22, .cat = .electric, .name = "Замена АКБ", .price = 8900, .dur = 30 },
    .{ .id = 23, .cat = .electric, .name = "Замена датчиков (компл)", .price = 4200, .dur = 120 },
};

/// Service ids are 1..services.len — index = id-1.
pub fn serviceAt(id: u32) ?*const Service {
    if (id == 0 or id > services.len) return null;
    return &services[@intCast(id - 1)];
}

test "catalog lookups stay in range" {
    try std.testing.expect(brandAt(brands.len) == null);
    try std.testing.expect(brandAt(0) != null);
    try std.testing.expect(modelAt(0, brands[0].models.len) == null);
    try std.testing.expectEqualStrings("Camry", modelAt(0, 0).?.name);
    try std.testing.expect(serviceAt(0) == null);
    try std.testing.expect(serviceAt(services.len + 1) == null);
    try std.testing.expectEqual(@as(u32, 18500), serviceAt(6).?.price);
    // every service id is unique and sequential
    for (services, 0..) |sv, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), sv.id);
    }
}
