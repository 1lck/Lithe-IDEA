// A small C++ file.
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#define LOG(x) std::cout << (x) << '\n'

namespace geometry {

template <typename T>
concept Numeric = std::is_arithmetic_v<T>;

/// A shape with an area.
class Shape {
public:
    virtual ~Shape() = default;
    [[nodiscard]] virtual double area() const noexcept = 0;
};

template <Numeric T>
class Rect final : public Shape {
public:
    Rect(T w, T h) : w_{w}, h_{h} {}
    double area() const noexcept override { return static_cast<double>(w_ * h_); }
    auto operator<=>(const Rect&) const = default;

private:
    T w_;
    T h_;
};

}  // namespace geometry

enum class Mode : unsigned char { Fast, Safe = 4 };

int main(int argc, char* argv[]) {
    using namespace geometry;
    std::vector<std::unique_ptr<Shape>> shapes;
    shapes.push_back(std::make_unique<Rect<int>>(3, 4));
    constexpr auto limit = 10'000ULL;
    auto raw = R"(raw "text")";
    auto total = 0.0;
    for (const auto& s : shapes) {
        total += s->area();
    }
    auto twice = [&total](double k) mutable -> double { return total * k; };
    /* block
       comment */
    if (argc > 1 && std::string{argv[1]} == "-v") {
        LOG(twice(2.0));
    }
    Mode mode = Mode::Safe;
    return mode == Mode::Fast || limit < 0x10 || raw == nullptr ? 1 : 0;
}
