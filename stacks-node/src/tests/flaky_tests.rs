use std::time::Duration;



#[test]
#[ignore]
fn flaky_01() {
    std::thread::sleep(Duration::from_secs(2));
    assert!(false);
}

#[test]
#[ignore]
fn flaky_02() {
    std::thread::sleep(Duration::from_secs(3));
    std::process::abort();
}

#[test]
#[ignore]
fn flaky_03() {
    assert!(true);
}
