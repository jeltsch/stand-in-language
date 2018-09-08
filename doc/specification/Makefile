base_name = sil-specification

all: $(base_name).pdf

$(base_name).pdf: $(base_name).tex
	pdflatex -draftmode $(base_name).tex
	pdflatex $(base_name).tex

clean:
	rm -f $(base_name).aux
	rm -f $(base_name).log
	rm -f $(base_name).out
	rm -f $(base_name).pdf
