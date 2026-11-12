# Sample CMake project
cmake_minimum_required(VERSION 3.20)
project(Sample VERSION 1.2.3 LANGUAGES C CXX)

option(SAMPLE_TESTS "Build the tests" ON)
set(CMAKE_CXX_STANDARD 20)
set(SOURCES src/main.cpp src/util.cpp)
set(CACHE_VAR "value" CACHE STRING "A cached variable")
list(APPEND SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/extra.cpp")
message(STATUS "Building ${PROJECT_NAME} ${PROJECT_VERSION} in $ENV{HOME}")

#[[ A bracket comment
    across lines ]]
set(BRACKET [=[
raw ${not_a_variable} text
]=])

if(WIN32 AND NOT MSVC)
  add_compile_options(-Wall -Wextra)
elseif(APPLE OR (UNIX AND CMAKE_SYSTEM_NAME STREQUAL "Linux"))
  add_definitions(-DPOSIX=1)
else()
  message(WARNING "unknown platform")
endif()

foreach(item IN LISTS SOURCES)
  get_filename_component(name ${item} NAME_WE)
endforeach()

function(sample_add target)
  cmake_parse_arguments(ARG "SHARED" "OUTPUT" "DEPENDS" ${ARGN})
  add_library(${target} $<IF:$<BOOL:${ARG_SHARED}>,SHARED,STATIC> ${ARG_UNPARSED_ARGUMENTS})
  target_link_libraries(${target} PRIVATE ${ARG_DEPENDS})
  set_target_properties(${target} PROPERTIES OUTPUT_NAME "${ARG_OUTPUT}" POSITION_INDEPENDENT_CODE TRUE)
endfunction()

macro(sample_option name)
  if(NOT DEFINED ${name})
    set(${name} OFF)
  endif()
endmacro()

find_package(Threads REQUIRED)
include(FindPackageHandleStandardArgs)
add_executable(sample ${SOURCES})
install(TARGETS sample RUNTIME DESTINATION bin)
while(COUNT LESS 10)
  math(EXPR COUNT "${COUNT} + 1")
  break()
endwhile()
return()
