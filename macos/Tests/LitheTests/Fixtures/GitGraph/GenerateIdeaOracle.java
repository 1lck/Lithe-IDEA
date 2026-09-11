// Verification helper, not part of ordinary tests. Run against IntelliJ's lib/*.
// Calls the upstream layout and print generator directly, never Lithe code.
import com.intellij.openapi.util.text.NaturalComparator;
import com.intellij.vcs.log.graph.*;
import com.intellij.vcs.log.graph.api.elements.*;
import com.intellij.vcs.log.graph.api.printer.*;
import com.intellij.vcs.log.graph.impl.permanent.*;
import com.intellij.vcs.log.graph.impl.print.*;
import com.intellij.vcs.log.graph.impl.print.elements.TerminalEdgePrintElement;
import java.nio.file.*;
import java.util.*;

public class GenerateIdeaOracle {
  record Commit(String id, List<String> parents) implements GraphCommit<String> {
    public String getId() { return id; }
    public List<String> getParents() { return parents; }
    public long getTimestamp() { return 0; } // Fixed input order; no date sorting.
  }
  record Ref(String name, int priority) {}
  static final Comparator<Ref> ORDER = Comparator.comparingInt(Ref::priority)
    .thenComparing(Ref::name, NaturalComparator.INSTANCE);

  public static void main(String[] args) throws Exception {
    var commits = new ArrayList<Commit>();
    var bestRefs = new ArrayList<Ref>();
    var branches = new HashSet<Integer>();
    for (var line : Files.readAllLines(Path.of(args.length > 3 ? args[3] : args[0]))) {
      var columns = line.split("\t", -1);
      commits.add(new Commit(columns[0], columns[1].isEmpty() ? List.of() : List.of(columns[1].split(" "))));
      var refs = new ArrayList<Ref>();
      for (var token : columns[2].trim().replace("(", "").replace(")", "").split(", ")) {
        if (token.isEmpty()) continue;
        if (token.startsWith("HEAD -> ")) { refs.add(new Ref("HEAD", 6)); token = token.substring(8); }
        boolean tag = token.startsWith("tag: ");
        if (!tag) branches.add(commits.size() - 1);
        int priority = tag ? 4 : token.equals("HEAD") ? 6
          : Set.of("origin/main", "origin/master").contains(token) ? 0
          : token.startsWith("origin/") ? 1
          : Set.of("main", "master").contains(token) ? 2 : 3;
        refs.add(new Ref(tag ? token.substring(5) : token, priority));
      }
      bestRefs.add(refs.stream().min(ORDER).orElse(null));
    }
    var unloaded = new HashMap<String, Integer>();
    var graph = PermanentLinearGraphBuilder.newInstance(commits)
      .build(hash -> unloaded.computeIfAbsent(hash, key -> -2 - unloaded.size()));
    var layout = GraphLayoutBuilder.build(graph, branches, (int a, int b) -> {
      var x = bestRefs.get(a); var y = bestRefs.get(b);
      if (x == null || y == null) return x == y ? a - b : x == null ? 1 : -1;
      int order = ORDER.compare(x, y);
      return order == 0 ? a - b : order;
    });
    var requested = new HashSet<String>();
    for (var line : Files.readAllLines(Path.of(args[0]))) requested.add(line.split("\t", -1)[0]);
    var visibleRows = new ArrayList<Integer>();
    for (int row = 0; row < commits.size(); row++) if (requested.contains(commits.get(row).id())) visibleRows.add(row);
    var visibleCommits = visibleRows.stream().map(commits::get).toList();
    // The no-argument build() gives every missing parent the SAME sentinel ID.
    // Real IDEA assigns unique IDs; otherwise two page-external parents alias
    // in the print generator's map of adjacent-row endpoints.
    var visibleUnloaded = new HashMap<String, Integer>();
    var visibleGraph = PermanentLinearGraphBuilder.newInstance(visibleCommits)
      .build(hash -> visibleUnloaded.computeIfAbsent(hash, key -> -2 - visibleUnloaded.size()));
    java.util.function.Function<Integer, Integer> visibleLI = row -> layout.getLayoutIndex(visibleRows.get(row));
    PrintElementPresentationManager presentation = new PrintElementPresentationManager() {
      public boolean isSelected(GraphPrintElement element) { return false; }
      public int getColorId(GraphElement element) {
        int node;
        if (element instanceof GraphNode n) node = n.getNodeIndex();
        else {
          var edge = (GraphEdge) element;
          var up = edge.getUpNodeIndex(); var down = edge.getDownNodeIndex();
          node = up == null ? down : down == null ? up
            : visibleLI.apply(up) >= visibleLI.apply(down) ? up : down;
        }
        node = visibleRows.get(node);
        int head = layout.getOneOfHeadNodeIndex(node);
        int index = layout.getLayoutIndex(node);
        var ref = bestRefs.get(head);
        return index != layout.getLayoutIndex(head) ? index : ref == null ? 0 : ref.name.hashCode();
      }
    };
    var printer = new PrintElementGeneratorImpl(visibleGraph, presentation, false,
      new GraphElementComparatorByLayoutIndex(visibleLI));
    var output = new ArrayList<String>();
    output.add("Width|" + printer.getRecommendedWidth());
    for (int row = 0; row < visibleCommits.size(); row++) {
      for (var element : printer.getPrintElements(row)) {
        if (element instanceof NodePrintElement) {
          output.add("Node|" + row + ":" + element.getPositionInCurrentRow() + ":" + visibleLI.apply(row) + ":" + element.getColorId());
        } else {
          var edge = (EdgePrintElement) element;
          output.add("Edge|" + row + ":" + edge.getPositionInCurrentRow() + ":" + edge.getPositionInOtherRow()
            + ":" + edge.getType() + ":" + edge.hasArrow() + ":" + (edge instanceof TerminalEdgePrintElement)
            + ":" + edge.getLineStyle() + ":" + edge.getColorId());
        }
      }
    }
    Collections.sort(output);
    Files.write(Path.of(args[1]), output);
    // Exercise the upstream generator with IDEA expUI / Islands theme values.
    var companion = com.intellij.vcs.log.graph.DefaultColorGenerator.Companion;
    var calculate = companion.getClass().getDeclaredMethod("calcColor", int.class);
    calculate.setAccessible(true);
    var colors = new ArrayList<String>();
    for (boolean dark : new boolean[] {false, true}) {
      javax.swing.UIManager.put("VersionControl.Log.Graph.saturation", 0.6f);
      javax.swing.UIManager.put("VersionControl.Log.Graph.brightness", dark ? 0.6f : 0.7f);
      for (int id : new int[] {1, 2, 5, 29, 3343801, -1754104450, Integer.MIN_VALUE, Integer.MAX_VALUE}) {
        var color = (java.awt.Color) calculate.invoke(companion, id);
        colors.add((dark ? "dark" : "light") + "|" + id + "|" + color.getRed() + ":" + color.getGreen() + ":" + color.getBlue());
      }
    }
    Files.write(Path.of(args[2]), colors);
  }
}
