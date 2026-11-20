package HelloWorld {
    private import ScalarValues::*;

    part def Vehicle {
        attribute mass : Real;
        attribute wheelCount : Integer = 4;
    }

    part vehicle : Vehicle {
        attribute redefines mass = 1500.0;
    }

    requirement vehicleHasMass {
        doc /* The vehicle shall declare a mass. */
        subject v : Vehicle;
        require constraint { v.mass > 0.0 }
    }
}
