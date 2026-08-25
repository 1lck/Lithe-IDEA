package com.example.demo.user;

import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public class UserRepository {
    public List<UserSummary> findAll() {
        return List.of(
                new UserSummary(1L, "Ada Lovelace"),
                new UserSummary(2L, "Grace Hopper")
        );
    }

    public record UserSummary(Long id, String name) {}
}
