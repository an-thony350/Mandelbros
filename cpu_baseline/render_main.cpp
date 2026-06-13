#include "functions.hpp"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

struct RenderConfig {
    int set = Mandelbrot;
    int width = 320;
    int height = 180;
    int max_iter = 256;
    int threads = 2;

    double center_x = -0.5;
    double center_y = 0.0;
    double x_width = 3.5;

    double julia_real = -0.8;
    double julia_imag = 0.156;

    std::string out_rgb = "/tmp/fractalscope_cpu.rgb";
    std::string out_json = "/tmp/fractalscope_cpu.json";
};

void print_usage(const char* prog) {
    std::cout
        << "FractalScope CPU baseline renderer\n\n"
        << "Usage:\n"
        << "  " << prog << " [options]\n\n"
        << "Options:\n"
        << "  --set <mandelbrot|julia|burning_ship|tricorn|0|1|2|3>\n"
        << "  --width <pixels>\n"
        << "  --height <pixels>\n"
        << "  --max-iter <count>\n"
        << "  --threads <count>\n"
        << "  --center-x <value>\n"
        << "  --center-y <value>\n"
        << "  --x-width <value>\n"
        << "  --julia-real <value>\n"
        << "  --julia-imag <value>\n"
        << "  --out-rgb <path>\n"
        << "  --out-json <path>\n"
        << "  --help\n\n"
        << "Example:\n"
        << "  " << prog
        << " --set mandelbrot --width 320 --height 180 --max-iter 256"
        << " --center-x -0.5 --center-y 0.0 --x-width 3.5"
        << " --threads 2 --out-rgb /tmp/fractalscope_cpu.rgb"
        << " --out-json /tmp/fractalscope_cpu.json\n";
}

int parse_int(const std::string& text, const std::string& name) {
    char* end = 0;
    long value = std::strtol(text.c_str(), &end, 10);

    if (end == text.c_str() || *end != '\0') {
        throw std::runtime_error("Invalid integer for " + name + ": " + text);
    }
    if (value < std::numeric_limits<int>::min() || value > std::numeric_limits<int>::max()) {
        throw std::runtime_error("Integer out of range for " + name + ": " + text);
    }

    return static_cast<int>(value);
}

unsigned char parse_uchar_component(int value) {
    if (value < 0) {
        return 0;
    }
    if (value > 255) {
        return 255;
    }
    return static_cast<unsigned char>(value);
}

double parse_double(const std::string& text, const std::string& name) {
    char* end = 0;
    double value = std::strtod(text.c_str(), &end);

    if (end == text.c_str() || *end != '\0') {
        throw std::runtime_error("Invalid floating-point value for " + name + ": " + text);
    }

    return value;
}

std::string lower_copy(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return text;
}

int parse_set(const std::string& text) {
    const std::string value = lower_copy(text);

    if (value == "0" || value == "mandelbrot") {
        return Mandelbrot;
    }
    if (value == "1" || value == "julia") {
        return Julia;
    }
    if (value == "2" || value == "burning_ship" || value == "burning-ship" || value == "burningship") {
        return Burning_Ship;
    }
    if (value == "3" || value == "tricorn") {
        return Tricorn;
    }

    throw std::runtime_error("Invalid set: " + text);
}

std::string set_name(int set) {
    switch (set) {
        case Mandelbrot:
            return "Mandelbrot";
        case Julia:
            return "Julia";
        case Burning_Ship:
            return "Burning Ship";
        case Tricorn:
            return "Tricorn";
        default:
            return "Unknown";
    }
}

std::string set_slug(int set) {
    switch (set) {
        case Mandelbrot:
            return "mandelbrot";
        case Julia:
            return "julia";
        case Burning_Ship:
            return "burning_ship";
        case Tricorn:
            return "tricorn";
        default:
            return "unknown";
    }
}

RenderConfig parse_args(int argc, char** argv) {
    RenderConfig cfg;

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];

        if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            std::exit(0);
        }

        if (i + 1 >= argc) {
            throw std::runtime_error("Missing value after " + arg);
        }

        const std::string value = argv[++i];

        if (arg == "--set") {
            cfg.set = parse_set(value);
        } else if (arg == "--width") {
            cfg.width = parse_int(value, arg);
        } else if (arg == "--height") {
            cfg.height = parse_int(value, arg);
        } else if (arg == "--max-iter") {
            cfg.max_iter = parse_int(value, arg);
        } else if (arg == "--threads") {
            cfg.threads = parse_int(value, arg);
        } else if (arg == "--center-x") {
            cfg.center_x = parse_double(value, arg);
        } else if (arg == "--center-y") {
            cfg.center_y = parse_double(value, arg);
        } else if (arg == "--x-width") {
            cfg.x_width = parse_double(value, arg);
        } else if (arg == "--julia-real") {
            cfg.julia_real = parse_double(value, arg);
        } else if (arg == "--julia-imag") {
            cfg.julia_imag = parse_double(value, arg);
        } else if (arg == "--out-rgb") {
            cfg.out_rgb = value;
        } else if (arg == "--out-json") {
            cfg.out_json = value;
        } else {
            throw std::runtime_error("Unknown option: " + arg);
        }
    }

    if (cfg.width <= 0) {
        throw std::runtime_error("--width must be greater than zero");
    }
    if (cfg.height <= 0) {
        throw std::runtime_error("--height must be greater than zero");
    }
    if (cfg.max_iter <= 0) {
        throw std::runtime_error("--max-iter must be greater than zero");
    }
    if (cfg.threads <= 0) {
        throw std::runtime_error("--threads must be greater than zero");
    }
    if (cfg.x_width <= 0.0) {
        throw std::runtime_error("--x-width must be greater than zero");
    }

    if (cfg.threads > cfg.height) {
        cfg.threads = cfg.height;
    }

    return cfg;
}

void palette_for_iter(int iter, int max_iter, unsigned char& r, unsigned char& g, unsigned char& b) {
    if (iter >= max_iter) {
        r = 0;
        g = 0;
        b = 0;
        return;
    }

    const double gradient = static_cast<double>(iter) / static_cast<double>(max_iter);

    r = parse_uchar_component(static_cast<int>(9.0 * (1.0 - gradient) * gradient * gradient * gradient * 255.0));
    g = parse_uchar_component(static_cast<int>(15.0 * (1.0 - gradient) * (1.0 - gradient) * gradient * gradient * 255.0));
    b = parse_uchar_component(static_cast<int>(8.5 * (1.0 - gradient) * (1.0 - gradient) * (1.0 - gradient) * gradient * 255.0));
}

int calculate_pixel(const RenderConfig& cfg, double c_re, double c_im) {
    switch (cfg.set) {
        case Mandelbrot:
            return Mandelbrot_calculation(c_re, c_im, cfg.max_iter);
        case Julia:
            return Julia_calculation(cfg.julia_real, cfg.julia_imag, c_re, c_im, cfg.max_iter);
        case Burning_Ship:
            return Burning_Ship_calculation(c_re, c_im, cfg.max_iter);
        case Tricorn:
            return Tricorn_calculation(c_re, c_im, cfg.max_iter);
        default:
            return 0;
    }
}

void render_rows(const RenderConfig& cfg, std::vector<unsigned char>& image, int start_row, int end_row) {
    const double scale = cfg.x_width / static_cast<double>(cfg.width);

    for (int row = start_row; row < end_row; ++row) {
        const double c_im = cfg.center_y + (static_cast<double>(row) - static_cast<double>(cfg.height) / 2.0) * scale;

        for (int col = 0; col < cfg.width; ++col) {
            const double c_re = cfg.center_x + (static_cast<double>(col) - static_cast<double>(cfg.width) / 2.0) * scale;
            const int iter = calculate_pixel(cfg, c_re, c_im);

            unsigned char r = 0;
            unsigned char g = 0;
            unsigned char b = 0;
            palette_for_iter(iter, cfg.max_iter, r, g, b);

            const int index = (row * cfg.width + col) * 3;
            image[index + 0] = r;
            image[index + 1] = g;
            image[index + 2] = b;
        }
    }
}

std::vector<unsigned char> render_image(const RenderConfig& cfg) {
    std::vector<unsigned char> image(static_cast<size_t>(cfg.width) * static_cast<size_t>(cfg.height) * 3u, 0);
    std::vector<std::thread> workers;

    const int base_rows = cfg.height / cfg.threads;
    const int extra_rows = cfg.height % cfg.threads;
    int start_row = 0;

    for (int thread_index = 0; thread_index < cfg.threads; ++thread_index) {
        const int rows_for_thread = base_rows + (thread_index < extra_rows ? 1 : 0);
        const int end_row = start_row + rows_for_thread;

        workers.push_back(std::thread(render_rows, std::cref(cfg), std::ref(image), start_row, end_row));
        start_row = end_row;
    }

    for (size_t i = 0; i < workers.size(); ++i) {
        workers[i].join();
    }

    return image;
}

void write_rgb_file(const std::string& path, const std::vector<unsigned char>& image) {
    std::ofstream out(path.c_str(), std::ios::binary);

    if (!out) {
        throw std::runtime_error("Could not open RGB output file: " + path);
    }

    out.write(reinterpret_cast<const char*>(image.data()), static_cast<std::streamsize>(image.size()));

    if (!out) {
        throw std::runtime_error("Failed while writing RGB output file: " + path);
    }
}

void write_json_file(
    const RenderConfig& cfg,
    double render_seconds,
    double rgb_write_seconds,
    const std::string& path
) {
    const double pixels = static_cast<double>(cfg.width) * static_cast<double>(cfg.height);
    const double pixels_per_second = render_seconds > 0.0 ? pixels / render_seconds : 0.0;

    std::ofstream out(path.c_str());

    if (!out) {
        throw std::runtime_error("Could not open JSON output file: " + path);
    }

    out << std::fixed << std::setprecision(9);
    out << "{\n";
    out << "  \"renderer\": \"cpu_baseline\",\n";
    out << "  \"set\": \"" << set_slug(cfg.set) << "\",\n";
    out << "  \"set_name\": \"" << set_name(cfg.set) << "\",\n";
    out << "  \"width\": " << cfg.width << ",\n";
    out << "  \"height\": " << cfg.height << ",\n";
    out << "  \"pixels\": " << static_cast<long long>(cfg.width) * static_cast<long long>(cfg.height) << ",\n";
    out << "  \"max_iter\": " << cfg.max_iter << ",\n";
    out << "  \"threads\": " << cfg.threads << ",\n";
    out << "  \"center_x\": " << cfg.center_x << ",\n";
    out << "  \"center_y\": " << cfg.center_y << ",\n";
    out << "  \"x_width\": " << cfg.x_width << ",\n";
    out << "  \"julia_real\": " << cfg.julia_real << ",\n";
    out << "  \"julia_imag\": " << cfg.julia_imag << ",\n";
    out << "  \"render_seconds\": " << render_seconds << ",\n";
    out << "  \"rgb_write_seconds\": " << rgb_write_seconds << ",\n";
    out << "  \"pixels_per_second\": " << pixels_per_second << ",\n";
    out << "  \"out_rgb\": \"" << cfg.out_rgb << "\"\n";
    out << "}\n";

    if (!out) {
        throw std::runtime_error("Failed while writing JSON output file: " + path);
    }
}

} // namespace

int main(int argc, char** argv) {
    try {
        const RenderConfig cfg = parse_args(argc, argv);

        std::cout << "FractalScope CPU baseline renderer\n";
        std::cout << "set=" << set_slug(cfg.set) << "\n";
        std::cout << "resolution=" << cfg.width << "x" << cfg.height << "\n";
        std::cout << "max_iter=" << cfg.max_iter << "\n";
        std::cout << "threads=" << cfg.threads << "\n";

        const auto render_start = std::chrono::high_resolution_clock::now();
        const std::vector<unsigned char> image = render_image(cfg);
        const auto render_end = std::chrono::high_resolution_clock::now();

        const auto write_start = std::chrono::high_resolution_clock::now();
        write_rgb_file(cfg.out_rgb, image);
        const auto write_end = std::chrono::high_resolution_clock::now();

        const double render_seconds = std::chrono::duration<double>(render_end - render_start).count();
        const double rgb_write_seconds = std::chrono::duration<double>(write_end - write_start).count();

        write_json_file(cfg, render_seconds, rgb_write_seconds, cfg.out_json);

        const double pixels = static_cast<double>(cfg.width) * static_cast<double>(cfg.height);
        const double pixels_per_second = render_seconds > 0.0 ? pixels / render_seconds : 0.0;

        std::cout << std::fixed << std::setprecision(6);
        std::cout << "render_seconds=" << render_seconds << "\n";
        std::cout << "rgb_write_seconds=" << rgb_write_seconds << "\n";
        std::cout << "pixels_per_second=" << pixels_per_second << "\n";
        std::cout << "out_rgb=" << cfg.out_rgb << "\n";
        std::cout << "out_json=" << cfg.out_json << "\n";
        std::cout << "status=ok\n";
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << "\n";
        std::cerr << "Run with --help for usage.\n";
        return 1;
    }

    return 0;
}
