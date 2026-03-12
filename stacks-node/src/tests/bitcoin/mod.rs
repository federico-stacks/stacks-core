// Copyright (C) 2025 Stacks Open Internet Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

//! Bitcoin Integration Test Module
//!
//! Entry point for all bitcoin related test modules

mod core_controller_integrations;

mod proptest_examples {
    use proptest::prelude::*;

    use pinny::tag;

    proptest! {
        #[test]
        fn proptest_reverse_twice_is_identity(values in proptest::collection::vec(any::<u8>(), 0..64)) {
            let mut reversed = values.clone();
            reversed.reverse();
            reversed.reverse();
            prop_assert_eq!(reversed, values);
        }

        #[test]
        fn prop_proptest_cases_is_2500(_seed in any::<u8>()) {
            let proptest_cases = std::env::var("PROPTEST_CASES").unwrap_or_default();
            prop_assert_eq!(proptest_cases, "2500");
        }

        #[tag(prop)]
        #[test]
        fn another_proptest_cases_is_2500(_seed in any::<u8>()) {
            let proptest_cases = std::env::var("PROPTEST_CASES").unwrap_or_default();
            prop_assert_eq!(proptest_cases, "2500");
        }

        //#[tag(prop)]
        #[test]
        fn failing_proptest(_seed in any::<u8>()) {
            let proptest_cases = std::env::var("PROPTEST_CASES").unwrap_or_default();
            prop_assert_ne!(proptest_cases, "2500");
            
            /*
            if _seed == 0 { // make the failing stored seed pass
                prop_assert_eq!(proptest_cases, "2500");
            } else {  // make failing with a new seed
                prop_assert_ne!(proptest_cases, "2500");
            }
            */

        }
    }
}